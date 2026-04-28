import CryptoKit
import Foundation

// Public contracts shared by Core, route orchestration, and concrete transports.
public struct CallGroup: Equatable, Sendable {
    public let id: UUID
    public let accessSecret: String?

    public init(id: UUID, accessSecret: String? = nil) {
        self.id = id
        self.accessSecret = accessSecret
    }
}

public struct GroupAccessCredential: Equatable, Sendable {
    public let groupID: UUID
    public let secret: String

    public init(groupID: UUID, secret: String) {
        self.groupID = groupID
        self.secret = secret
    }

    public nonisolated var groupHash: String {
        var input = Data(groupID.uuidString.utf8)
        input.append(0)
        input.append(contentsOf: secret.utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated var symmetricKey: SymmetricKey {
        var input = Data("ride-intercom-audio-v1".utf8)
        input.append(0)
        input.append(contentsOf: groupID.uuidString.utf8)
        input.append(0)
        input.append(contentsOf: secret.utf8)
        return SymmetricKey(data: SHA256.hash(data: input))
    }
}

public enum TransportRoute: String, Equatable, Sendable {
    case local = "Local"
    case internet = "Internet"
}

public enum OutboundAudioPacket: Equatable, Sendable {
    case voice(frameID: Int, samples: [Float] = [])
}

public enum AudioCodecIdentifier: String, Codable, Equatable, Sendable {
    case pcm16
    case heAACv2
    case opus
}



public enum ApplicationDataDelivery: String, Codable, Equatable, Sendable {
    case reliable
    case unreliable
}

public struct ApplicationDataMessage: Codable, Equatable, Sendable {
    public let namespace: String
    public let payload: Data
    public let delivery: ApplicationDataDelivery

    public init(namespace: String, payload: Data, delivery: ApplicationDataDelivery = .reliable) {
        self.namespace = namespace
        self.payload = payload
        self.delivery = delivery
    }
}

public struct AudioTransmitMetadata: Codable, Equatable, Sendable {
    public let mediaCodec: AudioCodecIdentifier


    public init(
        mediaCodec: AudioCodecIdentifier

    ) {
        self.mediaCodec = mediaCodec

    }
}

public struct EncodedVoicePacket: Codable, Equatable, Sendable {
    public let frameID: Int
    public let codec: AudioCodecIdentifier
    public let payload: Data

    public static func make(frameID: Int, samples: [Float]) throws -> EncodedVoicePacket {
        EncodedVoicePacket(frameID: frameID, codec: .pcm16, payload: PCMAudioCodec.encode(samples))
    }

    public func decodeSamples() throws -> [Float] {
        try PCMAudioCodec.decode(payload)
    }
}

public struct AudioPacketEnvelope: Codable, Equatable, Sendable {
    public enum PacketKind: String, Codable, Equatable, Sendable {
        case voice
    }

    public let groupID: UUID
    public let streamID: UUID
    public let sequenceNumber: Int
    public let sentAt: TimeInterval
    public let kind: PacketKind
    public let frameID: Int?
    public let samples: [Float]
    public let encodedVoice: EncodedVoicePacket?

    public init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        kind: PacketKind,
        frameID: Int?,
        samples: [Float] = [],
        encodedVoice: EncodedVoicePacket? = nil
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.kind = kind
        self.frameID = frameID
        self.samples = samples
        self.encodedVoice = encodedVoice
    }

    public init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        encodedVoice: EncodedVoicePacket
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.kind = .voice
        self.frameID = encodedVoice.frameID
        self.samples = []
        self.encodedVoice = encodedVoice
    }

    public init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        packet: OutboundAudioPacket
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt

        switch packet {
        case .voice(let frameID, let samples):
            if let encodedVoice = try? EncodedVoicePacket.make(frameID: frameID, samples: samples) {
                self.kind = .voice
                self.frameID = frameID
                self.samples = []
                self.encodedVoice = encodedVoice
            } else {
                self.kind = .voice
                self.frameID = frameID
                self.samples = samples
                self.encodedVoice = nil
            }
        }
    }

    public var packet: OutboundAudioPacket? {
        switch kind {
        case .voice:
            if let encodedVoice,
               let decodedSamples = try? encodedVoice.decodeSamples() {
                return .voice(frameID: encodedVoice.frameID, samples: decodedSamples)
            }
            guard let frameID else { return nil }
            return .voice(frameID: frameID, samples: samples)
        }
    }
}

public struct ReceivedAudioPacket: Equatable, Sendable {
    public let peerID: String
    public let envelope: AudioPacketEnvelope
    public let packet: OutboundAudioPacket

    public init(peerID: String, envelope: AudioPacketEnvelope, packet: OutboundAudioPacket) {
        self.peerID = peerID
        self.envelope = envelope
        self.packet = packet
    }
}

enum RouteControlMessage: Equatable, Sendable {
    case keepalive
    case handshake(HandshakeMessage)
}

public struct HandshakeMessage: Codable, Equatable, Sendable {
    public let groupHash: String
    public let memberID: String
    public let nonce: String
    public let mac: String

    public init(groupHash: String, memberID: String, nonce: String, mac: String) {
        self.groupHash = groupHash
        self.memberID = memberID
        self.nonce = nonce
        self.mac = mac
    }

    public nonisolated static func make(
        credential: GroupAccessCredential,
        memberID: String,
        nonce: String = UUID().uuidString
    ) -> HandshakeMessage {
        let groupHash = credential.groupHash
        return HandshakeMessage(
            groupHash: groupHash,
            memberID: memberID,
            nonce: nonce,
            mac: makeMAC(groupHash: groupHash, memberID: memberID, nonce: nonce, secret: credential.secret)
        )
    }

    public nonisolated func verify(credential: GroupAccessCredential) -> Bool {
        guard groupHash == credential.groupHash else { return false }
        let expectedMAC = Self.makeMAC(
            groupHash: groupHash,
            memberID: memberID,
            nonce: nonce,
            secret: credential.secret
        )
        return mac == expectedMAC
    }

    private nonisolated static func makeMAC(groupHash: String, memberID: String, nonce: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = [groupHash, memberID, nonce].joined(separator: "|")
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum LocalNetworkRejectReason: String, Equatable, Sendable {
    case groupMismatch = "group mismatch"
    case handshakeInvalid = "handshake invalid"
}

public enum LocalNetworkStatus: Equatable, Sendable {
    case idle
    case advertisingBrowsing
    case invited
    case invitationReceived
    case connected
    case rejected(LocalNetworkRejectReason)
    case unavailable
}

public struct LocalNetworkEvent: Equatable, Sendable {
    public let status: LocalNetworkStatus
    public let peerID: String?
    public let occurredAt: TimeInterval?

    public init(status: LocalNetworkStatus, peerID: String? = nil, occurredAt: TimeInterval? = nil) {
        self.status = status
        self.peerID = peerID
        self.occurredAt = occurredAt
    }
}

public struct OutboundPacketDiagnostics: Equatable, Sendable {
    public let route: TransportRoute
    public let streamID: UUID
    public let sequenceNumber: Int
    public let packetKind: AudioPacketEnvelope.PacketKind
    public let metadata: AudioTransmitMetadata?

    public init(
        route: TransportRoute,
        streamID: UUID,
        sequenceNumber: Int,
        packetKind: AudioPacketEnvelope.PacketKind,
        metadata: AudioTransmitMetadata?
    ) {
        self.route = route
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.packetKind = packetKind
        self.metadata = metadata
    }
}

public enum TransportEvent: Equatable, Sendable {
    case localNetworkStatus(LocalNetworkEvent)
    case connected(peerIDs: [String])
    case authenticated(peerIDs: [String])
    case receivedApplicationData(peerID: String, message: ApplicationDataMessage)
    case disconnected
    case linkFailed(internetAvailable: Bool)
    case receivedPacket(ReceivedAudioPacket)
    case outboundPacketBuilt(OutboundPacketDiagnostics)
}

public protocol CallSession: AnyObject {
    var onEvent: (@MainActor (TransportEvent) -> Void)? { get set }
    var activeRouteDebugTypeName: String { get }

    func startStandby(group: CallGroup)
    func connect(group: CallGroup)
    func startMedia()
    func stopMedia()
    func disconnect()
    func sendAudioFrame(_ frame: OutboundAudioPacket)
    func sendConnectionKeepalive()
    func sendApplicationData(_ message: ApplicationDataMessage)
}

public enum RouteKind: String, CaseIterable, Codable, Sendable {
    case multipeer
    case webRTC
}

public struct CallRouteConfiguration: Codable, Equatable, Sendable {
    public var enabledRoutes: Set<RouteKind>
    public var preferredRoute: RouteKind
    public var automaticFallbackEnabled: Bool
    public var automaticRestoreToPreferredEnabled: Bool
    public var multipeerStandbyEnabled: Bool
    public var webRTCWarmStandbyEnabled: Bool
    public var fallbackDelay: TimeInterval
    public var restoreProbeDuration: TimeInterval
    public var handoverFadeDuration: TimeInterval

    public init(
        enabledRoutes: Set<RouteKind> = [.multipeer, .webRTC],
        preferredRoute: RouteKind = .multipeer,
        automaticFallbackEnabled: Bool = true,
        automaticRestoreToPreferredEnabled: Bool = true,
        multipeerStandbyEnabled: Bool = true,
        webRTCWarmStandbyEnabled: Bool = true,
        fallbackDelay: TimeInterval = 3.0,
        restoreProbeDuration: TimeInterval = 7.5,
        handoverFadeDuration: TimeInterval = 0.35
    ) {
        self.enabledRoutes = enabledRoutes
        self.preferredRoute = preferredRoute
        self.automaticFallbackEnabled = automaticFallbackEnabled
        self.automaticRestoreToPreferredEnabled = automaticRestoreToPreferredEnabled
        self.multipeerStandbyEnabled = multipeerStandbyEnabled
        self.webRTCWarmStandbyEnabled = webRTCWarmStandbyEnabled
        self.fallbackDelay = fallbackDelay
        self.restoreProbeDuration = restoreProbeDuration
        self.handoverFadeDuration = handoverFadeDuration
    }
}

public struct RouteCapabilities: Equatable, Sendable {
    public var supportsLocalDiscovery: Bool
    public var supportsOfflineOperation: Bool
    public var supportsManagedMediaStream: Bool
    public var supportsAppManagedPacketMedia: Bool
    public var supportsReliableControl: Bool
    public var supportsUnreliableControl: Bool
    public var supportsReliableApplicationData: Bool
    public var supportsUnreliableApplicationData: Bool
    public var requiresSignaling: Bool

    public init(
        supportsLocalDiscovery: Bool,
        supportsOfflineOperation: Bool,
        supportsManagedMediaStream: Bool,
        supportsAppManagedPacketMedia: Bool,
        supportsReliableControl: Bool,
        supportsUnreliableControl: Bool,
        supportsReliableApplicationData: Bool,
        supportsUnreliableApplicationData: Bool,
        requiresSignaling: Bool
    ) {
        self.supportsLocalDiscovery = supportsLocalDiscovery
        self.supportsOfflineOperation = supportsOfflineOperation
        self.supportsManagedMediaStream = supportsManagedMediaStream
        self.supportsAppManagedPacketMedia = supportsAppManagedPacketMedia
        self.supportsReliableControl = supportsReliableControl
        self.supportsUnreliableControl = supportsUnreliableControl
        self.supportsReliableApplicationData = supportsReliableApplicationData
        self.supportsUnreliableApplicationData = supportsUnreliableApplicationData
        self.requiresSignaling = requiresSignaling
    }
}

public enum RouteMediaMode: Equatable, Sendable {
    case appManagedPacketAudio
    case managedMediaStream
}

public protocol CallRoute: AnyObject {
    var kind: RouteKind { get }
    var capabilities: RouteCapabilities { get }
    var onEvent: (@MainActor (TransportEvent) -> Void)? { get set }
    var debugTypeName: String { get }
    var mediaMode: RouteMediaMode { get }

    func startStandby(group: CallGroup)
    func activate(group: CallGroup)
    func startMedia()
    func stopMedia()
    func deactivate()
    func sendAudioFrame(_ frame: OutboundAudioPacket)
    func sendConnectionKeepalive()
    func sendApplicationData(_ message: ApplicationDataMessage)
}
