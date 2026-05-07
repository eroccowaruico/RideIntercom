#if canImport(MultipeerConnectivity)
import Foundation
import MultipeerConnectivity
import OSLog

public final class MultipeerLocalRoute: RTCCallRoute, @unchecked Sendable {
    public let kind: RouteKind = .multipeer
    public var capabilities: RouteCapabilities {
        RouteCapabilities(
            supportsLocalDiscovery: true,
            supportsOfflineOperation: true,
            supportsRouteManagedMedia: false,
            supportsAppManagedPacketAudio: true,
            supportsReliableApplicationData: true,
            supportsUnreliableApplicationData: true,
            requiresSignaling: false,
            supportedAudioCodecs: audioPolicy.preferredCodecs,
            backendName: "MultipeerConnectivity"
        )
    }
    public let mediaOwnership: AudioMediaOwnership = .appManagedPacketAudio
    public var events: AsyncStream<RouteEvent> { eventSource.stream }

    private let eventSource = EventSource<RouteEvent>()
    private let localDisplayName: String
    private let audioPolicy: RTCAudioPolicy
    private let packetAudioReceiveConfiguration: PacketAudioReceiveConfiguration
    private var transport: MultipeerConnectionTransport?
    private var mediaSession: MultipeerPacketMediaSession?
    private var packetAudioDrainTask: Task<Void, Never>?
    private var activePeerCount = 0

    public init(
        displayName: String,
        audioPolicy: RTCAudioPolicy = RTCAudioPolicy(),
        packetAudioReceiveConfiguration: PacketAudioReceiveConfiguration = PacketAudioReceiveConfiguration()
    ) {
        self.localDisplayName = displayName
        self.audioPolicy = audioPolicy
        self.packetAudioReceiveConfiguration = packetAudioReceiveConfiguration
    }

    public func prepare(_ request: CallStartRequest) async {
        let mediaSession: MultipeerPacketMediaSession
        do {
            mediaSession = try MultipeerPacketMediaSession(
                request: request,
                receiveConfiguration: packetAudioReceiveConfiguration
            )
        } catch RTCAudioPolicyError.noMutuallySupportedCodec(let preferred, let supported) {
            eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: false, reason: "No supported packet audio codec")))
            eventSource.yield(.error(kind, .unsupportedAudioCodec(kind, requested: preferred, supported: supported)))
            eventSource.yield(.stateChanged(kind, .failed))
            return
        } catch {
            eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: false, reason: "Packet audio codec setup failed")))
            eventSource.yield(.error(kind, .connectionFailed(kind, "Packet audio codec setup failed: \(error.localizedDescription)")))
            eventSource.yield(.stateChanged(kind, .failed))
            return
        }

        let transport = MultipeerConnectionTransport(request: request, displayName: localDisplayName)
        transport.onEvent = { [weak self] event in
            self?.handleTransportEvent(event)
        }
        self.transport = transport
        self.mediaSession = mediaSession
        eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: true)))
        eventSource.yield(.stateChanged(kind, .standby))
    }

    public func startConnection() async {
        transport?.start()
        eventSource.yield(.stateChanged(kind, .connecting))
    }

    public func stopConnection() async {
        packetAudioDrainTask?.cancel()
        packetAudioDrainTask = nil
        transport?.stop()
        transport = nil
        mediaSession = nil
        activePeerCount = 0
        eventSource.yield(.stateChanged(kind, .disconnected))
    }

    public func startMedia() async {
        mediaSession?.isActive = true
        eventSource.yield(.stateChanged(kind, .mediaReady))
    }

    public func stopMedia() async {
        packetAudioDrainTask?.cancel()
        packetAudioDrainTask = nil
        mediaSession?.isActive = false
    }

    public func sendAudioPacket(_ packet: RTCAudioPacket) async {
        guard let payload = try? mediaSession?.makePayload(from: packet) else { return }
        transport?.send(payload)
    }

    public func sendApplicationData(_ message: ApplicationDataMessage) async {
        guard let payload = try? MultipeerPayloadBuilder.makeApplicationDataPayload(message) else { return }
        transport?.send(payload)
    }

    public func setLocalMute(_ muted: Bool) async {}
    public func setOutputMute(_ muted: Bool) async {}

    private func handleTransportEvent(_ event: MultipeerConnectionEvent) {
        switch event {
        case .state(let state):
            eventSource.yield(.stateChanged(kind, state))
        case .members(let peers):
            activePeerCount = peers.count
            let members = peers.map {
                CallMemberState(peer: PeerDescriptor(id: $0, displayName: $0.rawValue), route: kind, isConnected: true)
            }
            eventSource.yield(.membersChanged(kind, members))
            eventSource.yield(.metricsChanged(RouteMetrics(route: kind, activePeerCount: peers.count)))
        case .message(let message, let peerID):
            handleWireMessage(message, from: peerID)
        case .failed(let message):
            eventSource.yield(.error(kind, .connectionFailed(kind, message)))
            eventSource.yield(.stateChanged(kind, .failed))
        }
    }

    private func handleWireMessage(_ message: MultipeerWireMessage, from peerID: PeerID) {
        switch message {
        case .control(let payload):
            handleControlPayload(payload, from: peerID)
        case .applicationData(let message):
            eventSource.yield(.receivedApplicationData(kind, ReceivedApplicationData(peerID: peerID, message: message)))
        case .packetAudio(let envelope):
            guard let report = try? mediaSession?.accept(
                envelope,
                from: peerID,
                receivedAt: Date().timeIntervalSince1970
            ) else { return }
            publishPacketAudio(report)
            schedulePacketAudioDrainIfNeeded()
        }
    }

    private func publishPacketAudio(_ report: PacketAudioReceiveBufferReport) {
        for frame in report.readyPackets {
            eventSource.yield(.receivedAudioPacket(kind, frame))
        }
        eventSource.yield(.metricsChanged(RouteMetrics(
            route: kind,
            activePeerCount: activePeerCount,
            audioPlayoutDelay: packetAudioReceiveConfiguration.playoutDelay,
            receivedAudioFrameCount: report.receivedPacketCount,
            droppedAudioFrameCount: report.droppedPacketCount,
            queuedAudioFrameCount: report.queuedPacketCount
        )))
    }

    private func schedulePacketAudioDrainIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard let delay = mediaSession?.timeUntilNextReadyPacket(now: now) else { return }
        packetAudioDrainTask?.cancel()
        packetAudioDrainTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.drainPacketAudio()
        }
    }

    private func drainPacketAudio() {
        guard let report = mediaSession?.drain(now: Date().timeIntervalSince1970) else { return }
        publishPacketAudio(report)
        schedulePacketAudioDrainIfNeeded()
    }

    private func handleControlPayload(_ payload: RouteControlPayload, from peerID: PeerID) {
        switch payload {
        case .keepalive:
            break
        case .handshake(let handshake):
            guard transport?.accept(handshake, from: peerID) == true else {
                eventSource.yield(.error(kind, .connectionFailed(kind, "Multipeer handshake rejected: \(peerID.rawValue)")))
                return
            }
            eventSource.yield(.stateChanged(kind, .authenticated))
        }
    }
}

enum MultipeerConnectionEvent {
    case state(RouteConnectionState)
    case members([PeerID])
    case message(MultipeerWireMessage, PeerID)
    case failed(String)
}

final class MultipeerConnectionTransport: NSObject {
    var onEvent: ((MultipeerConnectionEvent) -> Void)?

    private let request: CallStartRequest
    private let credential: RTCCredential?
    private let localPeerID: MCPeerID
    private let session: MCSession
    private let logger = Logger(subsystem: "com.yowamushi-inc.RideIntercom", category: "rtc-multipeer")
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var authenticatedPeers: Set<PeerID> = []
    private var pendingInvites: Set<String> = []

    init(request: CallStartRequest, displayName: String) {
        self.request = request
        self.credential = request.credential
        self.localPeerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    func start() {
        stopDiscovery()
        authenticatedPeers.removeAll()
        onEvent?(.state(.connecting))

        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: credential.map { [LocalDiscoveryInfo.groupHashKey: $0.groupHash] },
            serviceType: LocalDiscoveryInfo.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: LocalDiscoveryInfo.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        stopDiscovery()
        session.disconnect()
        authenticatedPeers.removeAll()
        onEvent?(.state(.disconnected))
    }

    func send(_ payload: TransportPayload) {
        guard !session.connectedPeers.isEmpty else { return }
        do {
            try session.send(payload.data, toPeers: session.connectedPeers, with: payload.mcSendMode)
        } catch {
            logger.error("Failed to send Multipeer payload: \(error.localizedDescription, privacy: .public)")
        }
    }

    func accept(_ handshake: RouteHandshakeMessage, from peerID: PeerID) -> Bool {
        guard let credential else {
            authenticatedPeers.insert(peerID)
            onEvent?(.members(Array(authenticatedPeers)))
            return true
        }
        guard handshake.verify(credential: credential) else { return false }
        authenticatedPeers.insert(peerID)
        onEvent?(.members(Array(authenticatedPeers)))
        return true
    }

    private func stopDiscovery() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        pendingInvites.removeAll()
    }

    private func sendHandshake(to peerID: MCPeerID) {
        guard let credential else {
            authenticatedPeers.insert(PeerID(rawValue: peerID.displayName))
            onEvent?(.members(Array(authenticatedPeers)))
            onEvent?(.state(.authenticated))
            return
        }
        do {
            let handshake = RouteHandshakeMessage.make(credential: credential, senderID: request.localPeer.id)
            let payload = try MultipeerPayloadBuilder.makeControlPayload(.handshake(handshake))
            try session.send(payload.data, toPeers: [peerID], with: payload.mcSendMode)
        } catch {
            logger.error("Failed to send Multipeer handshake: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension MultipeerConnectionTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard peerID != localPeerID else { return }
        if let credential, info?[LocalDiscoveryInfo.groupHashKey] != credential.groupHash { return }
        guard !pendingInvites.contains(peerID.displayName), !session.connectedPeers.contains(peerID) else { return }
        pendingInvites.insert(peerID.displayName)
        browser.invitePeer(
            peerID,
            to: session,
            withContext: credential.flatMap { LocalInvitationContext(groupHash: $0.groupHash).encoded },
            timeout: 10
        )
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        pendingInvites.remove(peerID.displayName)
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        onEvent?(.failed(error.localizedDescription))
    }
}

extension MultipeerConnectionTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        if let credential, LocalInvitationContext.decode(context)?.groupHash != credential.groupHash {
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        onEvent?(.failed(error.localizedDescription))
    }
}

extension MultipeerConnectionTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            pendingInvites.remove(peerID.displayName)
            onEvent?(.state(.connected))
            sendHandshake(to: peerID)
        case .connecting:
            onEvent?(.state(.connecting))
        case .notConnected:
            pendingInvites.remove(peerID.displayName)
            authenticatedPeers.remove(PeerID(rawValue: peerID.displayName))
            onEvent?(.members(Array(authenticatedPeers)))
            onEvent?(.state(session.connectedPeers.isEmpty ? .disconnected : .connected))
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            let message = try MultipeerPayloadBuilder.decode(data, credential: credential)
            onEvent?(.message(message, PeerID(rawValue: peerID.displayName)))
        } catch {
            logger.debug("Ignoring unknown Multipeer payload from \(peerID.displayName, privacy: .public)")
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

final class MultipeerPacketMediaSession {
    var isActive = false

    private let credential: RTCCredential?
    private let sequencer: PacketAudioSequencer
    private var filter: PacketAudioReceiveFilter
    private var receiveBuffer: PacketAudioReceiveBuffer

    init(
        request: CallStartRequest,
        receiveConfiguration: PacketAudioReceiveConfiguration = PacketAudioReceiveConfiguration()
    ) throws {
        let supportedCodecs = request.audioPolicy.preferredCodecs
        guard !supportedCodecs.isEmpty else {
            throw RTCAudioPolicyError.noMutuallySupportedCodec(preferred: [], supported: [])
        }
        self.credential = request.credential
        self.sequencer = PacketAudioSequencer(
            sessionID: request.sessionID,
            senderID: request.localPeer.id
        )
        self.filter = PacketAudioReceiveFilter(sessionID: request.sessionID, acceptedCodecs: supportedCodecs)
        self.receiveBuffer = PacketAudioReceiveBuffer(configuration: receiveConfiguration)
    }

    func makePayload(from packet: RTCAudioPacket) throws -> TransportPayload? {
        guard isActive else { return nil }
        return try MultipeerPayloadBuilder.makePacketAudioPayload(sequencer.makeEnvelope(from: packet), credential: credential)
    }

    func accept(
        _ envelope: PacketAudioEnvelope,
        from peerID: PeerID,
        receivedAt: TimeInterval
    ) throws -> PacketAudioReceiveBufferReport? {
        guard isActive else { return nil }
        guard let filtered = try filter.accept(envelope, from: peerID) else { return nil }
        receiveBuffer.enqueue(filtered, receivedAt: receivedAt)
        return receiveBuffer.drain(now: receivedAt)
    }

    func drain(now: TimeInterval) -> PacketAudioReceiveBufferReport? {
        guard isActive else { return nil }
        return receiveBuffer.drain(now: now)
    }

    func timeUntilNextReadyPacket(now: TimeInterval) -> TimeInterval? {
        receiveBuffer.timeUntilNextReadyPacket(now: now)
    }
}

enum LocalDiscoveryInfo {
    static let serviceType = "ride-intercom"
    static let groupHashKey = "groupHash"
}

private struct LocalInvitationContext: Codable, Equatable {
    var groupHash: String
    var encoded: Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data?) -> LocalInvitationContext? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

private extension TransportPayload {
    var mcSendMode: MCSessionSendDataMode {
        switch mode {
        case .reliable:
            .reliable
        case .unreliable:
            .unreliable
        }
    }
}
#endif
