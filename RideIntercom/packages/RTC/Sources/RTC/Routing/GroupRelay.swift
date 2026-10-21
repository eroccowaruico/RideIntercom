import CryptoKit
import Foundation

enum RelayBody: Codable, Equatable, Sendable {
    case presence
    case leave
    case audio(RTCAudioPacket)
    case application(ApplicationDataMessage)
    var delivery: ApplicationDataDelivery {
        switch self {
        case .audio, .presence: .unreliable
        case .leave: .reliable
        case .application(let message): message.delivery
        }
    }
}

/// Group-key authenticated, bounded flooding. A gateway is any member with links
/// on both networks. No leader lease can strand members behind a failed gateway.
/// Every origin/epoch/sequence is forwarded at most once per device, with <= 8 hops.
struct GroupRelay: Sendable {
    static let namespace = "rtc.group-relay.v1"
    static let presenceLifetime: TimeInterval = 8
    private struct Envelope: Codable {
        var session: String
        var origin: PeerDescriptor
        var epoch: UUID
        var sequence: UInt64
        var path: [PeerID]
        var body: RelayBody
        var internetReady: Bool
    }
    struct Reception: Equatable {
        var peer: PeerDescriptor
        var body: RelayBody
        var forward: Data?
        var didRestart: Bool
    }
    private struct Member: Sendable {
        var peer: PeerDescriptor
        var epoch: UUID
        var retired: [UUID] = []
        var highest: UInt64 = 0
        var seen = [UInt64?](repeating: nil, count: 1024)
        var presenceSequence: UInt64 = 0
        var lastPresence: TimeInterval
        var left = false
        var internetReady = false
        mutating func accept(_ sequence: UInt64) -> Bool {
            guard sequence >= highest || highest - sequence < 1024 else { return false }
            let index = Int(sequence % 1024)
            guard seen[index] != sequence else { return false }
            seen[index] = sequence; highest = max(highest, sequence)
            return true
        }
    }
    private let request: CallStartRequest
    var internetReady = false
    private let epoch = UUID()
    private var sequence: UInt64 = 0
    private var peers: [PeerID: Member] = [:]
    init(request: CallStartRequest) { self.request = request }

    mutating func make(_ body: RelayBody, now: TimeInterval) throws -> Data {
        sequence &+= 1
        return try encode(Envelope(session: request.sessionID, origin: request.localPeer, epoch: epoch,
                                   sequence: sequence, path: [request.localPeer.id], body: body, internetReady: internetReady))
    }

    mutating func receive(_ bytes: Data, from hop: PeerID, now: TimeInterval) -> Reception? {
        guard bytes.count <= 32768, var envelope = try? decode(bytes), envelope.session == request.sessionID,
              envelope.origin.id != request.localPeer.id, envelope.path.first == envelope.origin.id,
              envelope.path.last == hop, (1...8).contains(envelope.path.count),
              Set(envelope.path).count == envelope.path.count, !envelope.path.contains(request.localPeer.id),
              !envelope.origin.id.rawValue.isEmpty, envelope.origin.id.rawValue.utf8.count <= 80,
              envelope.origin.displayName.utf8.count <= 320 else { return nil }
        let id = envelope.origin.id
        let isPresence = envelope.body == .presence
        var didRestart = false
        if peers[id] == nil {
            guard isPresence else { return nil }
            if peers.count >= 7, let expired = peers.filter({ $0.value.left || now - $0.value.lastPresence >= Self.presenceLifetime })
                .min(by: { $0.value.lastPresence < $1.value.lastPresence })?.key { peers[expired] = nil }
            guard peers.count < 7 else { return nil }
            peers[id] = Member(peer: envelope.origin, epoch: envelope.epoch, lastPresence: now)
        }
        guard var member = peers[id] else { return nil }
        if member.epoch != envelope.epoch {
            guard isPresence, !member.retired.contains(envelope.epoch) else { return nil }
            didRestart = true
            let retired = Array((member.retired + [member.epoch]).suffix(8))
            member = Member(peer: envelope.origin, epoch: envelope.epoch, retired: retired, lastPresence: now)
        }
        if isPresence, envelope.sequence <= member.presenceSequence { return nil }
        guard member.accept(envelope.sequence) else { return nil }
        if isPresence { member.lastPresence = now; member.presenceSequence = envelope.sequence; member.left = false; member.peer = envelope.origin; member.internetReady = envelope.internetReady }
        if envelope.body == .leave { member.left = true; member.presenceSequence = envelope.sequence }
        if case .audio(var packet) = envelope.body {
            guard !member.left, now - member.lastPresence < Self.presenceLifetime,
                  packet.payload.count <= 8192, request.audioPolicy.preferredCodecs.contains(packet.codec),
                  packet.format.sampleRate.isFinite, (8_000...48_000).contains(packet.format.sampleRate),
                  (1...2).contains(packet.format.channelCount) else { return nil }
            // A capture restart may reset its counter. Relay epochs own playback ordering.
            packet.sequenceNumber = envelope.sequence
            envelope.body = .audio(packet)
        }
        peers[id] = member
        envelope.path.append(request.localPeer.id)
        let forwarded = envelope.path.count < 8 ? try? encode(envelope) : nil
        return Reception(peer: envelope.origin, body: envelope.body, forward: forwarded, didRestart: didRestart)
    }

    func members(now: TimeInterval) -> [PeerDescriptor] {
        peers.values.filter { !$0.left && now - $0.lastPresence < Self.presenceLifetime }
            .map(\.peer).sorted { $0.id.rawValue < $1.id.rawValue }
    }
    func internetGateways(now: TimeInterval) -> Set<PeerID> {
        Set(peers.values.filter { !$0.left && $0.internetReady && now - $0.lastPresence < Self.presenceLifetime }.map { $0.peer.id })
    }
    private func encode(_ envelope: Envelope) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(envelope)
        guard let credential = request.credential else { return data }
        return try AES.GCM.seal(data, using: SymmetricKey(data: credential.sharedSecret)).combined!
    }
    private func decode(_ data: Data) throws -> Envelope {
        let plain: Data
        if let credential = request.credential {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: credential.sharedSecret))
        } else { plain = data }
        return try PropertyListDecoder().decode(Envelope.self, from: plain)
    }
}
