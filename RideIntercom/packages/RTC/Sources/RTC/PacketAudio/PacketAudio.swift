import CryptoKit
import Foundation

struct PacketAudioEnvelope: Codable, Equatable, Sendable {
    var sessionID: String
    var senderID: PeerID
    var packet: RTCAudioPacket
}

struct PacketAudioSequencer: Sendable {
    private let sessionID: String
    private let senderID: PeerID

    init(sessionID: String, senderID: PeerID) {
        self.sessionID = sessionID
        self.senderID = senderID
    }

    func makeEnvelope(from packet: RTCAudioPacket) -> PacketAudioEnvelope {
        PacketAudioEnvelope(
            sessionID: sessionID,
            senderID: senderID,
            packet: packet
        )
    }
}

struct PacketAudioReceiveFilter: Sendable {
    private let sessionID: String
    private let acceptedCodecs: Set<RTCAudioCodecIdentifier>
    private var windows: [PeerID: SequenceWindow] = [:]

    init(sessionID: String, acceptedCodecs: [RTCAudioCodecIdentifier]) {
        self.sessionID = sessionID
        self.acceptedCodecs = Set(acceptedCodecs)
    }

    mutating func accept(_ envelope: PacketAudioEnvelope, from peerID: PeerID) throws -> FilteredPacketAudioPacket? {
        guard envelope.sessionID == sessionID else { return nil }
        guard acceptedCodecs.contains(envelope.packet.codec) else {
            throw RTCAudioPolicyError.unsupportedCodec(envelope.packet.codec)
        }
        guard windows[peerID, default: SequenceWindow()].accept(envelope.packet.sequenceNumber) else { return nil }
        return FilteredPacketAudioPacket(
            received: ReceivedAudioPacket(
                peerID: peerID,
                packet: envelope.packet
            )
        )
    }

    mutating func reset() {
        windows.removeAll()
    }

    mutating func removePeer(_ peerID: PeerID) {
        windows.removeValue(forKey: peerID)
    }

    // A fixed sequence window allows reordering without retaining every packet
    // for the whole call. Older packets cannot become playable again on eviction.
    private struct SequenceWindow: Sendable {
        private static let capacity: UInt64 = 1_024
        private var highest: UInt64 = 0
        private var slots = [UInt64?](repeating: nil, count: Int(capacity))

        mutating func accept(_ sequence: UInt64) -> Bool {
            if sequence < highest, highest - sequence >= Self.capacity { return false }
            let index = Int(sequence % Self.capacity)
            guard slots[index] != sequence else { return false }
            slots[index] = sequence
            highest = max(highest, sequence)
            return true
        }
    }
}

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

        var readyPackets: [QueuedPacket] = []
        var pendingPackets: [QueuedPacket] = []
        for queuedPacket in queuedPackets {
            if now - queuedPacket.receivedAt >= configuration.playoutDelay {
                readyPackets.append(queuedPacket)
            } else {
                pendingPackets.append(queuedPacket)
            }
        }
        queuedPackets = pendingPackets

        let ready = readyPackets
            .sorted { left, right in
                left.sortKey < right.sortKey
            }
            .map(\.filtered.received)

        for received in ready { lastDeliveredSequence[received.peerID] = received.packet.sequenceNumber }

        return PacketAudioReceiveBufferReport(
            readyPackets: ready,
            expiredPacketCount: expiredPacketCount,
            receivedPacketCount: receivedPacketCount,
            droppedPacketCount: droppedPacketCount,
            queuedPacketCount: queuedPackets.count
        )
    }

    mutating func recordRejectedPacket() {
        droppedPacketCount += 1
    }

    mutating func reset() {
        self = Self(configuration: configuration)
    }

    mutating func removePeer(_ peerID: PeerID) {
        queuedPackets.removeAll { $0.filtered.received.peerID == peerID }
        lastDeliveredSequence.removeValue(forKey: peerID)
    }

    mutating func drainReadyPackets(now: TimeInterval) -> [ReceivedAudioPacket] {
        drain(now: now).readyPackets
    }

    func timeUntilNextReadyPacket(now: TimeInterval) -> TimeInterval? {
        queuedPackets
            .map { max(0, configuration.playoutDelay - (now - $0.receivedAt)) }
            .min()
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
    case keepalive
    case handshake(RouteHandshakeMessage)
}

enum MultipeerWireMessage: Codable, Equatable, Sendable {
    case control(RouteControlPayload)
    case applicationData(ApplicationDataMessage)
    case packetAudio(PacketAudioEnvelope)
}

enum TransportSendMode: Equatable, Sendable {
    case reliable
    case unreliable
}

struct TransportPayload: Equatable, Sendable {
    var data: Data
    var mode: TransportSendMode
}

enum MultipeerPayloadBuilder {
    static func makeControlPayload(_ payload: RouteControlPayload) throws -> TransportPayload {
        let mode: TransportSendMode
        switch payload {
        case .keepalive:
            mode = .unreliable
        case .handshake:
            mode = .reliable
        }
        return TransportPayload(data: try encode(.control(payload)), mode: mode)
    }

    static func makeApplicationDataPayload(_ message: ApplicationDataMessage) throws -> TransportPayload {
        let mode: TransportSendMode = message.delivery == .reliable ? .reliable : .unreliable
        return TransportPayload(data: try encode(.applicationData(message)), mode: mode)
    }

    static func makePacketAudioPayload(_ envelope: PacketAudioEnvelope, credential: RTCCredential?) throws -> TransportPayload {
        let messageData = try encode(.packetAudio(envelope))
        let data: Data
        if let credential {
            data = try PacketCrypto.seal(messageData, credential: credential)
        } else {
            data = messageData
        }
        return TransportPayload(data: data, mode: .unreliable)
    }

    static func decode(_ data: Data, credential: RTCCredential?) throws -> MultipeerWireMessage {
        if let decoded = try? JSONDecoder().decode(MultipeerWireMessage.self, from: data) {
            if credential != nil, case .packetAudio = decoded { throw DecodeError.unknownPayload }
            return decoded
        }
        guard let credential else {
            throw DecodeError.unknownPayload
        }
        return try JSONDecoder().decode(MultipeerWireMessage.self, from: PacketCrypto.open(data, credential: credential))
    }

    private static func encode(_ message: MultipeerWireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(message)
    }

    enum DecodeError: Error, Equatable {
        case unknownPayload
    }
}

enum PacketCrypto {
    static func seal(_ data: Data, credential: RTCCredential) throws -> Data {
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: credential.sharedSecret))
        guard let combined = box.combined else { throw CryptoError.missingCombinedRepresentation }
        return combined
    }

    static func open(_ data: Data, credential: RTCCredential) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: credential.sharedSecret))
    }

    enum CryptoError: Error, Equatable {
        case missingCombinedRepresentation
    }
}
