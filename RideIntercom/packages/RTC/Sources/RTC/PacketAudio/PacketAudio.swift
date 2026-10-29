import CryptoKit
import Foundation

struct FilteredPacketAudioPacket: Equatable, Sendable {
    var received: ReceivedAudioPacket
}

public struct PacketAudioReceiveConfiguration: Equatable, Sendable {
    public var playoutDelay: TimeInterval
    public var packetLifetime: TimeInterval

    public init(playoutDelay: TimeInterval = 0.015, packetLifetime: TimeInterval = 0.1) {
        self.playoutDelay = max(0, playoutDelay)
        self.packetLifetime = max(0, packetLifetime)
    }
}

struct PacketAudioReceiveBufferReport: Equatable, Sendable {
    var readyPackets: [ReceivedAudioPacket]
    var expiredPacketCount: Int
    var receivedPacketCount: Int
    var droppedPacketCount: Int
    var queuedPacketCount: Int

    init(
        readyPackets: [ReceivedAudioPacket],
        expiredPacketCount: Int,
        receivedPacketCount: Int,
        droppedPacketCount: Int,
        queuedPacketCount: Int
    ) {
        self.readyPackets = readyPackets
        self.expiredPacketCount = expiredPacketCount
        self.receivedPacketCount = receivedPacketCount
        self.droppedPacketCount = droppedPacketCount
        self.queuedPacketCount = queuedPacketCount
    }
}

struct PacketAudioReceiveBuffer: Sendable {
    let configuration: PacketAudioReceiveConfiguration
    private var queuedPackets: [QueuedPacket] = []
    private var lastDeliveredSequence: [PeerID: UInt64] = [:]
    private(set) var receivedPacketCount = 0
    private(set) var droppedPacketCount = 0

    var queuedPacketCount: Int {
        queuedPackets.count
    }

    init(configuration: PacketAudioReceiveConfiguration = PacketAudioReceiveConfiguration()) {
        self.configuration = configuration
    }

    mutating func enqueue(_ filtered: FilteredPacketAudioPacket, receivedAt: TimeInterval) {
        receivedPacketCount += 1
        if let last = lastDeliveredSequence[filtered.received.peerID], filtered.received.packet.sequenceNumber <= last {
            droppedPacketCount += 1
            return
        }
        if queuedPackets.count >= 256 { queuedPackets.removeFirst(); droppedPacketCount += 1 }
        queuedPackets.append(QueuedPacket(filtered: filtered, receivedAt: receivedAt))
    }

    mutating func drain(now: TimeInterval) -> PacketAudioReceiveBufferReport {
        let queuedCountBeforeExpiration = queuedPackets.count
        queuedPackets.removeAll { queuedPacket in
            now - queuedPacket.receivedAt >= configuration.packetLifetime
        }
        let expiredPacketCount = queuedCountBeforeExpiration - queuedPackets.count
        droppedPacketCount += expiredPacketCount

        var ready: [ReceivedAudioPacket] = []
        var pending: [QueuedPacket] = []
        // Sort before advancing each sender's independent sequence. Contiguous
        // packets can leave immediately; only an unresolved gap needs a timer.
        for queued in queuedPackets.sorted(by: { $0.sortKey < $1.sortKey }) {
            let received = queued.filtered.received
            let last = lastDeliveredSequence[received.peerID]
            let sequence = received.packet.sequenceNumber
            if let last, sequence <= last {
                droppedPacketCount += 1
                continue
            }
            // A participant can join an established stream at any sequence.
            // There is no observed gap until this receiver has a predecessor.
            let contiguous = last.map { $0 != UInt64.max && sequence == $0 + 1 } ?? true
            if contiguous || now - queued.receivedAt >= configuration.playoutDelay {
                ready.append(received)
                lastDeliveredSequence[received.peerID] = sequence
            } else {
                pending.append(queued)
            }
        }
        queuedPackets = pending

        return PacketAudioReceiveBufferReport(
            readyPackets: ready,
            expiredPacketCount: expiredPacketCount,
            receivedPacketCount: receivedPacketCount,
            droppedPacketCount: droppedPacketCount,
            queuedPacketCount: queuedPackets.count
        )
    }

    mutating func reset() {
        self = Self(configuration: configuration)
    }

    mutating func removePeer(_ peerID: PeerID) {
        queuedPackets.removeAll { $0.filtered.received.peerID == peerID }
        lastDeliveredSequence.removeValue(forKey: peerID)
    }

    private struct QueuedPacket: Sendable {
        var filtered: FilteredPacketAudioPacket
        var receivedAt: TimeInterval

        var sortKey: SortKey {
            SortKey(
                peerID: filtered.received.peerID.rawValue,
                sequenceNumber: filtered.received.packet.sequenceNumber
            )
        }
    }

    private struct SortKey: Comparable, Sendable {
        var peerID: String
        var sequenceNumber: UInt64

        static func < (left: SortKey, right: SortKey) -> Bool {
            if left.peerID != right.peerID {
                return left.peerID < right.peerID
            }
            return left.sequenceNumber < right.sequenceNumber
        }
    }
}

struct RouteHandshakeMessage: Codable, Equatable, Sendable {
    var groupHash: String
    var senderID: PeerID
    var nonce: String
    var mac: String

    static func make(credential: RTCCredential, senderID: PeerID, nonce: String = UUID().uuidString) -> RouteHandshakeMessage {
        RouteHandshakeMessage(
            groupHash: credential.groupHash,
            senderID: senderID,
            nonce: nonce,
            mac: mac(groupHash: credential.groupHash, senderID: senderID, nonce: nonce, secret: credential.sharedSecret)
        )
    }

    func verify(credential: RTCCredential) -> Bool {
        groupHash == credential.groupHash
            && mac == Self.mac(groupHash: groupHash, senderID: senderID, nonce: nonce, secret: credential.sharedSecret)
    }

    private static func mac(groupHash: String, senderID: PeerID, nonce: String, secret: Data) -> String {
        let key = SymmetricKey(data: secret)
        let message = [groupHash, senderID.rawValue, nonce].joined(separator: "|")
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum RouteControlPayload: Codable, Equatable, Sendable {
    case handshake(RouteHandshakeMessage)
}

enum MultipeerWireMessage: Codable, Equatable, Sendable {
    case control(RouteControlPayload)
    case applicationData(ApplicationDataMessage)
}

enum TransportSendMode: Equatable, Sendable {
    case reliable
    case unreliable
}

struct TransportPayload: Equatable, Sendable {
    var data: Data
    var mode: TransportSendMode
    var groupAudio: Data? = nil
}

enum MultipeerPayloadBuilder {
    static func makeControlPayload(_ payload: RouteControlPayload) throws -> TransportPayload {
        TransportPayload(data: try encode(.control(payload)), mode: .reliable)
    }

    static func makeApplicationDataPayload(_ message: ApplicationDataMessage) throws -> TransportPayload {
        let mode: TransportSendMode = message.delivery == .reliable ? .reliable : .unreliable
        return TransportPayload(data: try encode(.applicationData(message)), mode: mode,
            groupAudio: message.namespace == GroupRelay.namespace && mode == .unreliable ? message.payload : nil)
    }

    static func decode(_ data: Data) throws -> MultipeerWireMessage {
        try JSONDecoder().decode(MultipeerWireMessage.self, from: data)
    }

    private static func encode(_ message: MultipeerWireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(message)
    }

}
