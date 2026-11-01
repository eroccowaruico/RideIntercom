import CryptoKit
import Foundation
import Network

/// These are audio-device directions, not group participant identities.
public enum RTCAudioDeviceRole: String, Codable, Sendable {
    case controller, device
    var opposite: Self { self == .controller ? .device : .controller }
    var peer: PeerID { .init(rawValue: rawValue) }
}

/// Pass this discovery tuple through an authenticated companion channel.
/// It contains neither account credentials nor a group identifier.
public struct RTCAudioDeviceEndpoint: Codable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let domain: String

    public init(name: String, type: String, domain: String) {
        self.name = name; self.type = type; self.domain = domain
    }
}

public enum RTCAudioDeviceLinkError: Error, Equatable {
    case invalidKey, invalidPacket, stopped
}

/// One disposable, encrypted audio-device pair. No CallSession, group admission,
/// discovery browser, reliable audio, resend, or background bootstrap is created.
public final class RTCAudioDeviceLink: @unchecked Sendable {
    private let transport: LocalDatagramTransport
    private let state: State
    private let remote: PeerID
    private static let packetLifetime: TimeInterval = 0.1

    // Accessed only on the shared datagram owner queue.
    private final class State: @unchecked Sendable {
        var cipher: AudioDeviceCipher?
        var started = false
        var sendReady = false
        var lastReceivedAt: TimeInterval?
        var endpoint: RTCAudioDeviceEndpoint?
        init(cipher: AudioDeviceCipher) { self.cipher = cipher }
    }

    /// Key material must be a fresh 256-bit random secret for this session, sent
    /// only through an authenticated companion channel. Do not use a group key.
    /// Callbacks execute on the datagram queue: keep them short. Reentrant
    /// send/stop are supported, without a second callback/audio delivery queue.
    public init(sessionID: UUID, key: Data, role: RTCAudioDeviceRole,
                onReceive: @escaping @Sendable (RTCAudioPacket) -> Void,
                onEndpointChange: @escaping @Sendable (RTCAudioDeviceEndpoint?) -> Void = { _ in },
                onSendAvailabilityChange: @escaping @Sendable (Bool) -> Void = { _ in },
                onFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        let state = State(cipher: try AudioDeviceCipher(sessionID: sessionID, key: key, role: role))
        self.state = state
        remote = role.opposite.peer
        let remote = remote
        let transport = LocalDatagramTransport(peerID: role.peer, groupHash: sessionID.uuidString) { sender, bytes in
            guard state.started, sender == remote, let packet = state.cipher?.open(bytes) else { return }
            state.lastReceivedAt = ProcessInfo.processInfo.systemUptime
            onReceive(packet)
        }
        self.transport = transport
        transport.onAvailabilityChange = { [weak transport] in
            guard let transport else { return }
            let ready = state.started && state.cipher != nil && transport.isReady(for: remote)
            guard state.sendReady != ready else { return }
            state.sendReady = ready
            onSendAvailabilityChange(ready)
        }
        transport.onServiceChange = { endpoint in
            guard state.started, state.cipher != nil else { return }
            if case .service(let name, let type, let domain, _) = endpoint {
                state.endpoint = .init(name: name, type: type, domain: domain)
            } else { state.endpoint = nil }
            onEndpointChange(state.endpoint)
        }
        transport.onFailure = { reason in
            guard state.started, state.cipher != nil else { return }
            onFailure(reason)
        }
    }

    deinit { transport.stop() }

    public var endpoint: RTCAudioDeviceEndpoint? { transport.synchronized { state.endpoint } }
    /// Native UDP send resources are ready. This does not prove peer reachability,
    /// delivery, receipt, playback, or a bidirectional audio session.
    public var isSendReady: Bool { transport.synchronized { state.started && state.cipher != nil && transport.isReady(for: remote) } }
    /// Last authenticated audio receipt on this device's systemUptime clock.
    /// Nil means none in this active session. No wall-clock synchronization or
    /// network loss/peer-liveness inference is performed by this value.
    public var lastReceivedAt: TimeInterval? { transport.synchronized { state.lastReceivedAt } }
    public var statistics: RTCNetworkStatistics { transport.statistics }

    /// Calling start repeatedly does not reset sequence/key state. After stop,
    /// create a new session with fresh key material instead of restarting this one.
    public func start() throws {
        try transport.synchronized {
            guard state.cipher != nil else { throw RTCAudioDeviceLinkError.stopped }
            guard !state.started else { return }
            try transport.start()
            state.started = true
        }
    }

    /// Accept only the opposite endpoint of this pair, with the fixed UDP service.
    /// Ordinary native path recovery retains the same session keys and sequence.
    @discardableResult public func connect(to endpoint: RTCAudioDeviceEndpoint) -> Bool {
        transport.synchronized {
            let prefix = transport.serviceName(for: remote) + "-"
            guard state.started, state.cipher != nil, endpoint.type == LocalDatagramTransport.serviceType,
                  endpoint.domain == "local.", endpoint.name.hasPrefix(prefix),
                  endpoint.name.utf8.count == prefix.utf8.count + 12,
                  endpoint.name.dropFirst(prefix.count).allSatisfy({ $0.isHexDigit }) else { return false }
            transport.connect(serviceName: transport.serviceName(for: remote),
                endpoint: .service(name: endpoint.name, type: endpoint.type, domain: endpoint.domain, interface: nil))
            return true
        }
    }

    /// True means accepted for immediate UDP sending, not delivered or played.
    /// Queue contention never turns a newly requested send into delayed speech.
    @discardableResult public func send(_ packet: RTCAudioPacket) -> Bool {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        return transport.synchronized {
            guard state.started, ProcessInfo.processInfo.systemUptime - requestedAt < Self.packetLifetime,
                  let bytes = try? state.cipher?.seal(packet) else { return false }
            return transport.send(bytes, to: [remote]).contains(remote)
        }
    }

    /// Invalidates cryptographic state before cancelling native callbacks.
    public func stop() {
        transport.synchronized {
            state.started = false; state.cipher = nil; state.endpoint = nil; state.lastReceivedAt = nil
            transport.stop()
        }
    }
}

/// AES.GCM is the same authenticated primitive used by GroupRelay; group
/// membership/credentials/forwarding never enter the audio-device link.
struct AudioDeviceCipher {
    private struct Envelope: Codable {
        let session: UUID
        let role: RTCAudioDeviceRole
        let sequence: UInt64
        let packet: RTCAudioPacket
    }
    private let session: UUID
    private let role: RTCAudioDeviceRole
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sequence: UInt64 = 0
    private var lastReceived: UInt64?
    private static let namespace = Data("rtc.audio-device.v1".utf8)

    init(sessionID: UUID, key: Data, role: RTCAudioDeviceRole) throws {
        guard key.count == 32 else { throw RTCAudioDeviceLinkError.invalidKey }
        session = sessionID; self.role = role
        func directionKey(_ direction: RTCAudioDeviceRole) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: Data(sessionID.uuidString.utf8),
                info: Self.namespace + Data(direction.rawValue.utf8), outputByteCount: 32)
        }
        sendKey = directionKey(role); receiveKey = directionKey(role.opposite)
    }

    mutating func seal(_ packet: RTCAudioPacket) throws -> Data {
        guard Self.valid(packet), sequence < UInt64.max else { throw RTCAudioDeviceLinkError.invalidPacket }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let plain = try encoder.encode(Envelope(session: session, role: role, sequence: sequence, packet: packet))
        sequence += 1
        return try AES.GCM.seal(plain, using: sendKey, authenticating: Self.namespace).combined!
    }

    mutating func open(_ bytes: Data) -> RTCAudioPacket? {
        guard bytes.count <= 32_768,
              let box = try? AES.GCM.SealedBox(combined: bytes),
              let plain = try? AES.GCM.open(box, using: receiveKey, authenticating: Self.namespace),
              let envelope = try? PropertyListDecoder().decode(Envelope.self, from: plain),
              envelope.session == session, envelope.role == role.opposite, Self.valid(envelope.packet),
              lastReceived.map({ envelope.sequence > $0 }) ?? true else { return nil }
        // Only fully authenticated/validated audio advances replay state. No
        // reorder wait is added: a packet older than delivered speech is dropped.
        lastReceived = envelope.sequence
        return envelope.packet
    }

    private static func valid(_ packet: RTCAudioPacket) -> Bool {
        // Match the decoder's common allocation bound, without parsing any codec.
        // This audio-only link has no empty control/DTX packet representation.
        !packet.payload.isEmpty && packet.payload.count <= 8192 && packet.capturedAt.isFinite &&
        packet.format.sampleRate.isFinite && (8_000...48_000).contains(packet.format.sampleRate) &&
        (1...2).contains(packet.format.channelCount) &&
        (packet.sampleCount.map({ (1...(96_000 * packet.format.channelCount)).contains($0) }) ?? true) &&
        (packet.bitRate.map({ (0...1_536_000).contains($0) }) ?? true)
    }
}
