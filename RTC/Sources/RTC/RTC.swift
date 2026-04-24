import CryptoKit
import Foundation
import OSLog

#if canImport(MultipeerConnectivity)
import MultipeerConnectivity
#endif

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
    case keepalive
}

public enum AudioCodecIdentifier: String, Codable, Equatable, Sendable {
    case pcm16
    case heAACv2
    case opus
}

public enum AudioCodecFallbackReason: String, Codable, Equatable, Sendable {
    case codecUnavailable
    case encoderReturnedEmptyPayload
    case encodingFailed
}

public struct AudioTransmitMetadata: Codable, Equatable, Sendable {
    public let requestedCodec: AudioCodecIdentifier
    public let encodedCodec: AudioCodecIdentifier
    public let fallbackReason: AudioCodecFallbackReason?

    public init(
        requestedCodec: AudioCodecIdentifier,
        encodedCodec: AudioCodecIdentifier,
        fallbackReason: AudioCodecFallbackReason?
    ) {
        self.requestedCodec = requestedCodec
        self.encodedCodec = encodedCodec
        self.fallbackReason = fallbackReason
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
        case keepalive
    }

    public let groupID: UUID
    public let streamID: UUID
    public let sequenceNumber: Int
    public let sentAt: TimeInterval
    public let kind: PacketKind
    public let frameID: Int?
    public let samples: [Float]
    public let encodedVoice: EncodedVoicePacket?
    public let transmitMetadata: AudioTransmitMetadata?

    public init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        kind: PacketKind,
        frameID: Int?,
        samples: [Float] = [],
        encodedVoice: EncodedVoicePacket? = nil,
        transmitMetadata: AudioTransmitMetadata? = nil
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.kind = kind
        self.frameID = frameID
        self.samples = samples
        self.encodedVoice = encodedVoice
        self.transmitMetadata = transmitMetadata
    }

    public init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        encodedVoice: EncodedVoicePacket,
        transmitMetadata: AudioTransmitMetadata? = nil
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.kind = .voice
        self.frameID = encodedVoice.frameID
        self.samples = []
        self.encodedVoice = encodedVoice
        self.transmitMetadata = transmitMetadata
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
                self.transmitMetadata = AudioTransmitMetadata(
                    requestedCodec: .pcm16,
                    encodedCodec: .pcm16,
                    fallbackReason: nil
                )
            } else {
                self.kind = .keepalive
                self.frameID = nil
                self.samples = []
                self.encodedVoice = nil
                self.transmitMetadata = AudioTransmitMetadata(
                    requestedCodec: .pcm16,
                    encodedCodec: .pcm16,
                    fallbackReason: .encodingFailed
                )
            }
        case .keepalive:
            self.kind = .keepalive
            self.frameID = nil
            self.samples = []
            self.encodedVoice = nil
            self.transmitMetadata = AudioTransmitMetadata(
                requestedCodec: .pcm16,
                encodedCodec: .pcm16,
                fallbackReason: nil
            )
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
        case .keepalive:
            return .keepalive
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

public enum ControlMessage: Equatable, Sendable {
    case keepalive
    case handshake(HandshakeMessage)
    case peerMuteState(isMuted: Bool)
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
    case remotePeerMuteState(peerID: String, isMuted: Bool)
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
    func disconnect()
    func sendAudioFrame(_ frame: OutboundAudioPacket)
    func sendControl(_ message: ControlMessage)
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
    public var requiresSignaling: Bool

    public init(
        supportsLocalDiscovery: Bool,
        supportsOfflineOperation: Bool,
        supportsManagedMediaStream: Bool,
        supportsAppManagedPacketMedia: Bool,
        supportsReliableControl: Bool,
        supportsUnreliableControl: Bool,
        requiresSignaling: Bool
    ) {
        self.supportsLocalDiscovery = supportsLocalDiscovery
        self.supportsOfflineOperation = supportsOfflineOperation
        self.supportsManagedMediaStream = supportsManagedMediaStream
        self.supportsAppManagedPacketMedia = supportsAppManagedPacketMedia
        self.supportsReliableControl = supportsReliableControl
        self.supportsUnreliableControl = supportsUnreliableControl
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
    func deactivate()
    func sendAudioFrame(_ frame: OutboundAudioPacket)
    func sendControl(_ message: ControlMessage)
}

public final class RouteManager: CallSession {
    public var onEvent: (@MainActor (TransportEvent) -> Void)?
    public var activeRouteDebugTypeName: String {
        activeRoute?.debugTypeName ?? route(for: configuration.preferredRoute)?.debugTypeName ?? "NoRoute"
    }

    private let configuration: CallRouteConfiguration
    private let routes: [RouteKind: CallRoute]
    private var activeRouteKind: RouteKind?
    private var currentGroup: CallGroup?
    private var fallbackTask: Task<Void, Never>?

    public init(preferredRoute: CallRoute) {
        self.configuration = CallRouteConfiguration(
            enabledRoutes: [preferredRoute.kind],
            preferredRoute: preferredRoute.kind,
            automaticFallbackEnabled: false,
            automaticRestoreToPreferredEnabled: false
        )
        self.routes = [preferredRoute.kind: preferredRoute]
        bindRouteEvents()
    }

    public init(
        routes: [CallRoute],
        configuration: CallRouteConfiguration = CallRouteConfiguration()
    ) {
        self.configuration = configuration
        self.routes = Dictionary(
            uniqueKeysWithValues: routes
                .filter { configuration.enabledRoutes.contains($0.kind) }
                .map { ($0.kind, $0) }
        )
        bindRouteEvents()
    }

    deinit {
        fallbackTask?.cancel()
    }

    private var activeRoute: CallRoute? {
        activeRouteKind.flatMap(route(for:))
    }

    private func route(for kind: RouteKind) -> CallRoute? {
        routes[kind]
    }

    private func bindRouteEvents() {
        for route in routes.values {
            route.onEvent = { [weak self, weak route] event in
                guard let route else { return }
                self?.handleRouteEvent(event, from: route.kind)
            }
        }
    }

    public func startStandby(group: CallGroup) {
        currentGroup = group
        fallbackTask?.cancel()

        if configuration.multipeerStandbyEnabled,
           let multipeerRoute = route(for: .multipeer) {
            multipeerRoute.startStandby(group: group)
        }

        if configuration.preferredRoute != .multipeer,
           let preferredRoute = route(for: configuration.preferredRoute) {
            preferredRoute.startStandby(group: group)
        }
    }

    public func connect(group: CallGroup) {
        currentGroup = group
        fallbackTask?.cancel()

        if let preferredRoute = route(for: configuration.preferredRoute) {
            activeRouteKind = preferredRoute.kind
            preferredRoute.activate(group: group)
            scheduleFallbackIfNeeded(from: preferredRoute.kind)
            return
        }

        activateFirstAvailableRoute(group: group)
    }

    public func disconnect() {
        fallbackTask?.cancel()
        fallbackTask = nil
        for route in routes.values {
            route.deactivate()
        }
        activeRouteKind = nil
        currentGroup = nil
    }

    public func sendAudioFrame(_ frame: OutboundAudioPacket) {
        activeRoute?.sendAudioFrame(frame)
    }

    public func sendControl(_ message: ControlMessage) {
        activeRoute?.sendControl(message)
    }

    private func activateFirstAvailableRoute(group: CallGroup) {
        guard let route = routes.values.first else {
            Task { @MainActor [weak self] in
                self?.onEvent?(.linkFailed(internetAvailable: false))
            }
            return
        }
        activeRouteKind = route.kind
        route.activate(group: group)
    }

    private func scheduleFallbackIfNeeded(from routeKind: RouteKind) {
        guard configuration.automaticFallbackEnabled,
              routeKind == configuration.preferredRoute,
              routeKind != .webRTC,
              route(for: .webRTC) != nil,
              let group = currentGroup else { return }

        fallbackTask = Task { [weak self] in
            let delay = UInt64(max(0, self?.configuration.fallbackDelay ?? 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.activateFallbackRoute(group: group)
        }
    }

    private func activateFallbackRoute(group: CallGroup) {
        guard activeRouteKind == configuration.preferredRoute,
              let fallbackRoute = route(for: .webRTC) else { return }

        activeRouteKind = fallbackRoute.kind
        fallbackRoute.activate(group: group)
    }

    private func handleRouteEvent(_ event: TransportEvent, from routeKind: RouteKind) {
        updateActiveRouteIfNeeded(for: event, from: routeKind)
        Task { @MainActor [weak self] in
            self?.onEvent?(event)
        }
    }

    private func updateActiveRouteIfNeeded(for event: TransportEvent, from routeKind: RouteKind) {
        switch event {
        case .authenticated, .connected:
            if activeRouteKind == nil || routeKind == configuration.preferredRoute {
                activeRouteKind = routeKind
                fallbackTask?.cancel()
                fallbackTask = nil
            }
        case .disconnected, .linkFailed:
            guard activeRouteKind == routeKind,
                  configuration.automaticFallbackEnabled,
                  let group = currentGroup else { return }
            if let fallbackRoute = routes.values.first(where: { $0.kind != routeKind }) {
                activeRouteKind = fallbackRoute.kind
                fallbackRoute.activate(group: group)
            }
        default:
            break
        }
    }
}

public final class UnavailableCallSession: CallSession {
    public var onEvent: (@MainActor (TransportEvent) -> Void)?
    public var activeRouteDebugTypeName: String { "UnavailableCallSession" }

    public init() {}

    public func startStandby(group: CallGroup) {
        notifyUnavailable()
    }

    public func connect(group: CallGroup) {
        notifyUnavailable()
    }

    public func disconnect() {
        Task { @MainActor [weak self] in
            self?.onEvent?(.disconnected)
        }
    }

    public func sendAudioFrame(_ frame: OutboundAudioPacket) {}
    public func sendControl(_ message: ControlMessage) {}

    private func notifyUnavailable() {
        Task { @MainActor [weak self] in
            self?.onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .unavailable)))
            self?.onEvent?(.linkFailed(internetAvailable: false))
        }
    }
}

public final class WebRTCInternetRoute: CallRoute {
    public let kind: RouteKind = .webRTC
    public let capabilities = RouteCapabilities(
        supportsLocalDiscovery: false,
        supportsOfflineOperation: false,
        supportsManagedMediaStream: true,
        supportsAppManagedPacketMedia: false,
        supportsReliableControl: true,
        supportsUnreliableControl: false,
        requiresSignaling: true
    )
    public var onEvent: (@MainActor (TransportEvent) -> Void)?
    public let debugTypeName = "WebRTCInternetRoute"
    public let mediaMode: RouteMediaMode = .managedMediaStream

    public init() {}

    public func startStandby(group: CallGroup) {}

    public func activate(group: CallGroup) {
        notify(.linkFailed(internetAvailable: true))
    }

    public func deactivate() {
        notify(.disconnected)
    }

    public func sendAudioFrame(_ frame: OutboundAudioPacket) {}
    public func sendControl(_ message: ControlMessage) {}

    private func notify(_ event: TransportEvent) {
        Task { @MainActor [weak self] in
            self?.onEvent?(event)
        }
    }
}

#if canImport(MultipeerConnectivity)
public final class MultipeerLocalRoute: CallRoute {
    public let kind: RouteKind = .multipeer
    public let capabilities = RouteCapabilities(
        supportsLocalDiscovery: true,
        supportsOfflineOperation: true,
        supportsManagedMediaStream: false,
        supportsAppManagedPacketMedia: true,
        supportsReliableControl: true,
        supportsUnreliableControl: true,
        requiresSignaling: false
    )
    public var onEvent: (@MainActor (TransportEvent) -> Void)? {
        get { transport.onEvent }
        set { transport.onEvent = newValue }
    }
    public var debugTypeName: String { String(describing: type(of: transport)) }
    public let mediaMode: RouteMediaMode = .appManagedPacketAudio

    private let transport: MultipeerLocalTransport

    public init(displayName: String) {
        self.transport = MultipeerLocalTransport(displayName: displayName)
    }

    public func startStandby(group: CallGroup) {
        transport.connect(group: group)
    }

    public func activate(group: CallGroup) {
        transport.connect(group: group)
    }

    public func deactivate() {
        transport.disconnect()
    }

    public func sendAudioFrame(_ frame: OutboundAudioPacket) {
        transport.sendAudioFrame(frame)
    }

    public func sendControl(_ message: ControlMessage) {
        transport.sendControl(message)
    }
}

final class MultipeerLocalTransport: NSObject {
    let route: TransportRoute = .local
    var onEvent: (@MainActor (TransportEvent) -> Void)?

    private let localPeerID: MCPeerID
    private let session: MCSession
    private let logger = Logger(subsystem: "com.yowamushi-inc.RideIntercom", category: "rtc-multipeer")
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var credential: GroupAccessCredential?
    private var handshakeRegistry: HandshakeRegistry?
    private var sequencer: AudioPacketSequencer?
    private var receivedPacketFilter: ReceivedAudioPacketFilter?
    private(set) var receivedPackets: [ReceivedAudioPacket] = []

    init(displayName: String) {
        self.localPeerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        self.session.delegate = self
    }

    func connect(group: CallGroup) {
        stopDiscoveryAndSession()
        credential = LocalDiscoveryInfo.credential(for: group)
        handshakeRegistry = credential.map(HandshakeRegistry.init(credential:))
        sequencer = AudioPacketSequencer(groupID: group.id)
        receivedPacketFilter = ReceivedAudioPacketFilter(groupID: group.id)
        receivedPackets.removeAll()
        notify(.localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing)))

        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: credential.map(LocalDiscoveryInfo.makeDiscoveryInfo(for:)),
            serviceType: LocalNetworkConfiguration.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: LocalNetworkConfiguration.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func disconnect() {
        stopDiscoveryAndSession()
        credential = nil
        handshakeRegistry = nil
        sequencer = nil
        receivedPacketFilter = nil
        receivedPackets.removeAll()
        notify(.disconnected)
    }

    func sendAudioFrame(_ frame: OutboundAudioPacket) {
        send(frame)
    }

    func sendControl(_ message: ControlMessage) {
        switch message {
        case .keepalive:
            send(OutboundAudioPacket.keepalive)
        case .handshake, .peerMuteState:
            send(message)
        }
    }

    private func send(_ message: ControlMessage, toPeers peers: [MCPeerID]? = nil) {
        let targetPeers = peers ?? session.connectedPeers
        guard !targetPeers.isEmpty else { return }

        do {
            let payload = try MultipeerPayloadBuilder.makePayload(for: message)
            try session.send(payload.data, toPeers: targetPeers, with: payload.mcMode)
        } catch {
            logger.error("Failed to send control payload: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func send(_ packet: OutboundAudioPacket) {
        guard !session.connectedPeers.isEmpty, var sequencer else { return }

        do {
            let payload = try MultipeerPayloadBuilder.makePayload(
                for: packet,
                sequencer: &sequencer,
                credential: credential
            )
            let envelope = try MultipeerPayloadBuilder.decodeAudioPayload(payload.data, credential: credential)
            self.sequencer = sequencer
            notify(.outboundPacketBuilt(OutboundPacketDiagnostics(
                route: route,
                streamID: envelope.streamID,
                sequenceNumber: envelope.sequenceNumber,
                packetKind: envelope.kind,
                metadata: envelope.transmitMetadata
            )))
            try session.send(payload.data, toPeers: session.connectedPeers, with: payload.mcMode)
        } catch {
            logger.error("Failed to send audio payload: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopDiscoveryAndSession() {
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        session.disconnect()
        browser = nil
        advertiser = nil
    }

    private func notify(_ event: TransportEvent) {
        let event = event.withLocalNetworkTimestampIfNeeded()
        Task { @MainActor [weak self] in
            self?.onEvent?(event)
        }
    }
}

private extension TransportEvent {
    func withLocalNetworkTimestampIfNeeded(now: TimeInterval = Date().timeIntervalSince1970) -> TransportEvent {
        guard case .localNetworkStatus(let event) = self,
              event.occurredAt == nil else { return self }

        return .localNetworkStatus(LocalNetworkEvent(
            status: event.status,
            peerID: event.peerID,
            occurredAt: now
        ))
    }
}

extension MultipeerLocalTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard peerID != localPeerID else { return }
        guard let credential,
              LocalDiscoveryInfo.matches(info, credential: credential) else {
            notify(.localNetworkStatus(LocalNetworkEvent(status: .rejected(.groupMismatch), peerID: peerID.displayName)))
            return
        }

        notify(.localNetworkStatus(LocalNetworkEvent(status: .invited, peerID: peerID.displayName)))
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        notify(.localNetworkStatus(LocalNetworkEvent(status: .unavailable)))
        notify(.linkFailed(internetAvailable: false))
    }
}

extension MultipeerLocalTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        notify(.localNetworkStatus(LocalNetworkEvent(status: .invitationReceived, peerID: peerID.displayName)))
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        notify(.localNetworkStatus(LocalNetworkEvent(status: .unavailable)))
        notify(.linkFailed(internetAvailable: false))
    }
}

extension MultipeerLocalTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            if let credential {
                send(
                    .handshake(HandshakeMessage.make(credential: credential, memberID: localPeerID.displayName)),
                    toPeers: [peerID]
                )
            }
            notify(.localNetworkStatus(LocalNetworkEvent(status: .connected, peerID: peerID.displayName)))
            notify(.connected(peerIDs: session.connectedPeers.map(\.displayName)))
        case .connecting:
            break
        case .notConnected:
            notify(session.connectedPeers.isEmpty ? .disconnected : .connected(peerIDs: session.connectedPeers.map(\.displayName)))
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if handleControlPayload(data, fromPeer: peerID) {
            return
        }

        guard handshakeRegistry?.isAuthenticated(peerID: peerID.displayName) == true,
              var filter = receivedPacketFilter else { return }

        do {
            let envelope = try MultipeerPayloadBuilder.decodeAudioPayload(data, credential: credential)
            guard let received = filter.accept(envelope, fromPeerID: peerID.displayName) else {
                receivedPacketFilter = filter
                return
            }
            receivedPacketFilter = filter
            receivedPackets.append(received)
            notify(.receivedPacket(received))
        } catch {
            receivedPacketFilter = filter
        }
    }

    private func handleControlPayload(_ data: Data, fromPeer peerID: MCPeerID) -> Bool {
        guard let message = try? MultipeerPayloadBuilder.decodeControlPayload(data) else { return false }

        switch message {
        case .keepalive:
            return true
        case .handshake(let handshake):
            guard var registry = handshakeRegistry else { return true }
            switch registry.accept(handshake, fromPeerID: peerID.displayName) {
            case .accepted:
                handshakeRegistry = registry
                notify(.authenticated(peerIDs: registry.authenticatedPeerIDs))
            case .rejected:
                notify(.localNetworkStatus(LocalNetworkEvent(status: .rejected(.handshakeInvalid), peerID: peerID.displayName)))
                session.cancelConnectPeer(peerID)
            }
            return true
        case .peerMuteState(let isMuted):
            notify(.remotePeerMuteState(peerID: peerID.displayName, isMuted: isMuted))
            return true
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

private extension MultipeerPayload {
    var mcMode: MCSessionSendDataMode {
        switch mode {
        case .unreliable:
            .unreliable
        case .reliable:
            .reliable
        }
    }
}
#endif

public enum PCMAudioCodec {
    public static func encode(_ samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)

        for sample in samples {
            let clamped = min(1, max(-1, sample))
            let encodedSample = Int16((clamped * Float(Int16.max)).rounded())
            data.append(contentsOf: encodedSample.littleEndianBytes)
        }

        return data
    }

    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw CodecError.invalidByteCount
        }

        return stride(from: 0, to: data.count, by: MemoryLayout<Int16>.size).map { offset in
            let rawValue = Int16(littleEndian: data[offset].int16LittleEndian(with: data[offset + 1]))
            return Float(rawValue) / Float(Int16.max)
        }
    }

    public enum CodecError: Error, Equatable {
        case invalidByteCount
    }
}

private extension Int16 {
    var littleEndianBytes: [UInt8] {
        let value = littleEndian
        return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
}

private extension UInt8 {
    func int16LittleEndian(with highByte: UInt8) -> Int16 {
        Int16(bitPattern: UInt16(self) | (UInt16(highByte) << 8))
    }
}

public enum AudioPacketCodec {
    public static func encode(_ envelope: AudioPacketEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> AudioPacketEnvelope {
        try JSONDecoder().decode(AudioPacketEnvelope.self, from: data)
    }
}

enum EncryptedAudioPacketCodec {
    static func encode(_ envelope: AudioPacketEnvelope, credential: GroupAccessCredential) throws -> Data {
        let plaintext = try AudioPacketCodec.encode(envelope)
        let sealedBox = try AES.GCM.seal(plaintext, using: credential.symmetricKey)
        guard let combined = sealedBox.combined else {
            throw CryptoError.unavailableCombinedRepresentation
        }
        return combined
    }

    static func decode(_ data: Data, credential: GroupAccessCredential) throws -> AudioPacketEnvelope {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(sealedBox, using: credential.symmetricKey)
        return try AudioPacketCodec.decode(plaintext)
    }

    enum CryptoError: Error, Equatable {
        case unavailableCombinedRepresentation
    }
}

enum PacketCryptoService {
    static func encrypt(_ envelope: AudioPacketEnvelope, credential: GroupAccessCredential) throws -> Data {
        try EncryptedAudioPacketCodec.encode(envelope, credential: credential)
    }

    static func decrypt(_ data: Data, credential: GroupAccessCredential) throws -> AudioPacketEnvelope {
        try EncryptedAudioPacketCodec.decode(data, credential: credential)
    }
}

struct AudioPacketSequencer {
    let groupID: UUID
    private(set) var streamID: UUID
    private var nextSequenceNumber = 1

    init(groupID: UUID, streamID: UUID = UUID()) {
        self.groupID = groupID
        self.streamID = streamID
    }

    mutating func makeEnvelope(for packet: OutboundAudioPacket, sentAt: TimeInterval = Date().timeIntervalSince1970) -> AudioPacketEnvelope {
        let envelope: AudioPacketEnvelope
        switch packet {
        case .voice(let frameID, let samples):
            envelope = makeVoiceEnvelope(frameID: frameID, samples: samples, sentAt: sentAt)
        case .keepalive:
            envelope = AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: nextSequenceNumber,
                sentAt: sentAt,
                packet: .keepalive
            )
        }

        nextSequenceNumber += 1
        return envelope
    }

    private mutating func makeVoiceEnvelope(frameID: Int, samples: [Float], sentAt: TimeInterval) -> AudioPacketEnvelope {
        do {
            let encodedVoice = try EncodedVoicePacket.make(frameID: frameID, samples: samples)
            return AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: nextSequenceNumber,
                sentAt: sentAt,
                encodedVoice: encodedVoice,
                transmitMetadata: AudioTransmitMetadata(
                    requestedCodec: .pcm16,
                    encodedCodec: .pcm16,
                    fallbackReason: nil
                )
            )
        } catch {
            return AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: nextSequenceNumber,
                sentAt: sentAt,
                kind: .keepalive,
                frameID: nil,
                samples: [],
                encodedVoice: nil,
                transmitMetadata: AudioTransmitMetadata(
                    requestedCodec: .pcm16,
                    encodedCodec: .pcm16,
                    fallbackReason: .encodingFailed
                )
            )
        }
    }
}

struct ReceivedAudioPacketFilter {
    private let groupID: UUID
    private var seenPacketIDs: Set<PacketID> = []

    init(groupID: UUID) {
        self.groupID = groupID
    }

    mutating func accept(_ envelope: AudioPacketEnvelope, fromPeerID peerID: String) -> ReceivedAudioPacket? {
        guard envelope.groupID == groupID else { return nil }

        let packetID = PacketID(streamID: envelope.streamID, sequenceNumber: envelope.sequenceNumber)
        guard !seenPacketIDs.contains(packetID),
              let packet = envelope.packet else {
            return nil
        }

        seenPacketIDs.insert(packetID)
        return ReceivedAudioPacket(peerID: peerID, envelope: envelope, packet: packet)
    }

    private struct PacketID: Hashable {
        let streamID: UUID
        let sequenceNumber: Int
    }
}

struct HandshakeRegistry {
    enum Result: Equatable {
        case accepted
        case rejected
    }

    private let credential: GroupAccessCredential
    private(set) var authenticatedPeerIDs: [String] = []

    init(credential: GroupAccessCredential) {
        self.credential = credential
    }

    mutating func accept(_ message: HandshakeMessage, fromPeerID peerID: String) -> Result {
        guard message.verify(credential: credential) else { return .rejected }

        if !authenticatedPeerIDs.contains(peerID) {
            authenticatedPeerIDs.append(peerID)
        }
        return .accepted
    }

    func isAuthenticated(peerID: String) -> Bool {
        authenticatedPeerIDs.contains(peerID)
    }
}

enum LocalDiscoveryInfo {
    static let groupHashKey = "groupHash"

    static func credential(for group: CallGroup) -> GroupAccessCredential {
        GroupAccessCredential(groupID: group.id, secret: group.accessSecret ?? "local-dev-\(group.id.uuidString)")
    }

    static func makeDiscoveryInfo(for credential: GroupAccessCredential) -> [String: String] {
        [groupHashKey: credential.groupHash]
    }

    static func matches(_ info: [String: String]?, credential: GroupAccessCredential) -> Bool {
        info?[groupHashKey] == credential.groupHash
    }
}

struct LocalNetworkConfiguration {
    static let serviceType = "ride-intercom"
}

enum TransportSendMode: Equatable {
    case unreliable
    case reliable
}

struct MultipeerPayload: Equatable {
    let data: Data
    let mode: TransportSendMode
}

struct ControlPayloadEnvelope: Codable, Equatable {
    let kind: Kind
    let handshake: HandshakeMessage?
    let peerMuteStateIsMuted: Bool?

    enum Kind: String, Codable {
        case keepalive
        case handshake
        case peerMuteState
    }

    init(message: ControlMessage) {
        switch message {
        case .keepalive:
            kind = .keepalive
            handshake = nil
            peerMuteStateIsMuted = nil
        case .handshake(let handshake):
            kind = .handshake
            self.handshake = handshake
            peerMuteStateIsMuted = nil
        case .peerMuteState(let isMuted):
            kind = .peerMuteState
            handshake = nil
            peerMuteStateIsMuted = isMuted
        }
    }

    var message: ControlMessage? {
        switch kind {
        case .keepalive:
            .keepalive
        case .handshake:
            handshake.map(ControlMessage.handshake)
        case .peerMuteState:
            peerMuteStateIsMuted.map { .peerMuteState(isMuted: $0) }
        }
    }
}

enum MultipeerPayloadBuilder {
    static func makePayload(
        for packet: OutboundAudioPacket,
        sequencer: inout AudioPacketSequencer,
        credential: GroupAccessCredential? = nil,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) throws -> MultipeerPayload {
        let envelope = sequencer.makeEnvelope(for: packet, sentAt: sentAt)
        let data: Data
        if let credential {
            data = try PacketCryptoService.encrypt(envelope, credential: credential)
        } else {
            data = try AudioPacketCodec.encode(envelope)
        }
        return MultipeerPayload(data: data, mode: .unreliable)
    }

    static func makePayload(for message: ControlMessage) throws -> MultipeerPayload {
        let data = try JSONEncoder().encode(ControlPayloadEnvelope(message: message))
        let mode: TransportSendMode
        switch message {
        case .keepalive:
            mode = .unreliable
        case .handshake, .peerMuteState:
            mode = .reliable
        }
        return MultipeerPayload(data: data, mode: mode)
    }

    static func decodeControlPayload(_ data: Data) throws -> ControlMessage? {
        try JSONDecoder().decode(ControlPayloadEnvelope.self, from: data).message
    }

    static func decodeAudioPayload(_ data: Data, credential: GroupAccessCredential? = nil) throws -> AudioPacketEnvelope {
        if let credential {
            return try PacketCryptoService.decrypt(data, credential: credential)
        }
        return try AudioPacketCodec.decode(data)
    }
}
