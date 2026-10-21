#if canImport(MultipeerConnectivity)
import Foundation
@preconcurrency import MultipeerConnectivity
import OSLog

public actor MultipeerLocalRoute: RTCCallRoute {
    public let kind: RouteKind = .multipeer
    nonisolated public var capabilities: RouteCapabilities {
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
    nonisolated public var events: AsyncStream<RouteEvent> { eventSource.stream }

    private let eventSource = EventSource<RouteEvent>(isTransient: { $0.isTransient })
    private let localDisplayName: String
    private let audioPolicy: RTCAudioPolicy
    private let packetAudioReceiveConfiguration: PacketAudioReceiveConfiguration
    private var generation = UUID()
    private var transportEventsTask: Task<Void, Never>?
    private var transportSource: EventSource<MultipeerConnectionEvent>?
    private var transport: MultipeerConnectionTransport?
    private var mediaSession: MultipeerPacketMediaSession?
    private var packetAudioDrainTask: Task<Void, Never>?
    private var activePeers: Set<PeerID> = []

    public init(
        displayName: String,
        audioPolicy: RTCAudioPolicy = RTCAudioPolicy(),
        packetAudioReceiveConfiguration: PacketAudioReceiveConfiguration = PacketAudioReceiveConfiguration()
    ) {
        self.localDisplayName = displayName
        self.audioPolicy = audioPolicy
        self.packetAudioReceiveConfiguration = packetAudioReceiveConfiguration
    }

    deinit {
        transportEventsTask?.cancel()
        packetAudioDrainTask?.cancel()
        transport?.stop()
    }

    public func networkDiagnostics() async -> RTCRouteNetworkDiagnostics {
        .init(route: kind, statistics: .init(unavailableReason: "MultipeerConnectivity does not expose RTT, loss or buffered bytes"),
              eventDrops: ["route": eventSource.report, "transport": transportSource?.report ?? .init()])
    }
    public func prepare(_ request: CallStartRequest) async {
        eventSource.resetDiagnostics()
        generation = UUID()
        transportEventsTask?.cancel()
        packetAudioDrainTask?.cancel()
        transport?.stop()
        transport = nil
        mediaSession = nil
        activePeers.removeAll()
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
        let source = EventSource<MultipeerConnectionEvent>(isTransient: { $0.isTransient })
        transportSource = source
        transport.onEvent = { source.yield($0) }
        let generation = generation
        let events = source.stream
        transportEventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleTransportEvent(event, generation: generation)
            }
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
        generation = UUID()
        transportEventsTask?.cancel()
        transportEventsTask = nil
        packetAudioDrainTask?.cancel()
        packetAudioDrainTask = nil
        transport?.stop()
        transport = nil
        mediaSession = nil
        activePeers.removeAll()
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

    private func handleTransportEvent(_ event: MultipeerConnectionEvent, generation: UUID) {
        guard self.generation == generation else { return }
        switch event {
        case .state(let state):
            eventSource.yield(.stateChanged(kind, state))
        case .members(let peers):
            let currentPeers = Set(peers)
            for peer in activePeers.subtracting(currentPeers) {
                mediaSession?.removePeer(peer)
            }
            activePeers = currentPeers
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
            activePeerCount: activePeers.count,
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
        let generation = generation
        packetAudioDrainTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.drainPacketAudio(generation: generation)
        }
    }

    private func drainPacketAudio(generation: UUID) {
        guard self.generation == generation else { return }
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

enum MultipeerConnectionEvent: Sendable {
    var isTransient: Bool {
        switch self {
        case .message(.packetAudio, _): return true
        case .message(.applicationData(let message), _): return message.delivery == .unreliable
        default: return false
        }
    }

    case state(RouteConnectionState)
    case members([PeerID])
    case message(MultipeerWireMessage, PeerID)
    case failed(String)
}

final class MultipeerConnectionTransport: NSObject, @unchecked Sendable {
    var onEvent: ((MultipeerConnectionEvent) -> Void)?

    private let request: CallStartRequest
    private let credential: RTCCredential?
    private let localPeerID: MCPeerID
    private var session: MCSession
    // Bonjour's browser/monitor lifecycle belongs to the main run loop. Starting
    // and destroying it on another queue races its pending cancellation callback.
    private let queue = DispatchQueue.main
    private var isStopped = false
    private var connectedPeerIDs: Set<PeerID> = []
    private let logger = Logger(subsystem: "com.yowamushi-inc.RideIntercom", category: "rtc-multipeer")
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var authenticatedPeers: Set<PeerID> = []
    private var pendingInvites: Set<String> = []

    init(request: CallStartRequest, displayName: String) {
        self.request = request
        self.credential = request.credential
        self.localPeerID = MCPeerID(displayName: request.localPeer.id.rawValue)
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    private func onQueue<T>(_ operation: () -> T) -> T {
        if Thread.isMainThread { return operation() }
        return queue.sync(execute: operation)
    }

    func start() {
        onQueue { [self] in
            stopDiscovery()
            session.delegate = nil
            session.disconnect()
            session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self
            isStopped = false
            connectedPeerIDs.removeAll()
            authenticatedPeers.removeAll()
            onEvent?(.state(.connecting))

            let advertiser = MCNearbyServiceAdvertiser(
                peer: localPeerID,
                discoveryInfo: credential.map { [LocalDiscoveryInfo.groupHashKey: $0.groupHash] },
                serviceType: LocalDiscoveryInfo.serviceType
            )
            advertiser.delegate = self
            self.advertiser = advertiser
            advertiser.startAdvertisingPeer()

            let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: LocalDiscoveryInfo.serviceType)
            browser.delegate = self
            self.browser = browser
            browser.startBrowsingForPeers()

        }
    }

    func stop() {
        onQueue { [self] in
            isStopped = true
            connectedPeerIDs.removeAll()
            stopDiscovery()
            session.delegate = nil
            session.disconnect()
            authenticatedPeers.removeAll()
            onEvent?(.state(.disconnected))

        }
    }

    func send(_ payload: TransportPayload) {
        onQueue { [self] in
            guard !isStopped else { return }
            let peers = session.connectedPeers.filter { authenticatedPeers.contains(PeerID(rawValue: $0.displayName)) }
            guard !peers.isEmpty else { return }
            do {
                try session.send(payload.data, toPeers: peers, with: payload.mcSendMode)
            } catch {
                logger.error("Failed to send Multipeer payload: \(error.localizedDescription, privacy: .public)")
            }

        }
    }

    func accept(_ handshake: RouteHandshakeMessage, from peerID: PeerID) -> Bool {
        return onQueue { [self] in
            guard !isStopped, connectedPeerIDs.contains(peerID) else { return false }
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
    }

    private func stopDiscovery() {
        advertiser?.delegate = nil
        browser?.delegate = nil
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
        queue.async { [self] in
            guard !isStopped, self.browser === browser else { return }
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
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { [self] in
            guard !isStopped, self.browser === browser else { return }
            pendingInvites.remove(peerID.displayName)

        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        queue.async { [self] in
            guard !isStopped, self.browser === browser else { return }
            onEvent?(.failed(error.localizedDescription))

        }
    }
}

extension MultipeerConnectionTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let acceptedSession: MCSession? = onQueue {
            guard !isStopped, self.advertiser === advertiser else { return nil }
            if let credential, LocalInvitationContext.decode(context)?.groupHash != credential.groupHash { return nil }
            return session
        }
        invitationHandler(acceptedSession != nil, acceptedSession)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        queue.async { [self] in
            guard !isStopped, self.advertiser === advertiser else { return }
            onEvent?(.failed(error.localizedDescription))

        }
    }
}

extension MultipeerConnectionTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async { [self] in
            guard !isStopped, self.session === session else { return }
            switch state {
            case .connected:
                connectedPeerIDs.insert(PeerID(rawValue: peerID.displayName))
                pendingInvites.remove(peerID.displayName)
                onEvent?(.state(.connected))
                sendHandshake(to: peerID)
            case .connecting:
                onEvent?(.state(.connecting))
            case .notConnected:
                connectedPeerIDs.remove(PeerID(rawValue: peerID.displayName))
                pendingInvites.remove(peerID.displayName)
                authenticatedPeers.remove(PeerID(rawValue: peerID.displayName))
                onEvent?(.members(Array(authenticatedPeers)))
                onEvent?(.state(connectedPeerIDs.isEmpty ? .disconnected : (authenticatedPeers.isEmpty ? .connected : .authenticated)))
            @unknown default:
                break
            }

        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        queue.async { [self] in
            guard !isStopped, self.session === session else { return }
            do {
                let message = try MultipeerPayloadBuilder.decode(data, credential: credential)
                if case .control(.handshake) = message {
                    guard connectedPeerIDs.contains(PeerID(rawValue: peerID.displayName)) else { return }
                } else {
                    guard authenticatedPeers.contains(PeerID(rawValue: peerID.displayName)) else { return }
                }
                onEvent?(.message(message, PeerID(rawValue: peerID.displayName)))
            } catch {
                logger.debug("Ignoring unknown Multipeer payload from \(peerID.displayName, privacy: .public)")
            }

        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

final class MultipeerPacketMediaSession {
    var isActive = false {
        didSet {
            if !isActive {
                filter.reset()
                receiveBuffer.reset()
            }
        }
    }

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

    func removePeer(_ peerID: PeerID) {
        filter.removePeer(peerID)
        receiveBuffer.removePeer(peerID)
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
        guard let filtered = try filter.accept(envelope, from: peerID) else {
            receiveBuffer.recordRejectedPacket()
            return receiveBuffer.drain(now: receivedAt)
        }
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
