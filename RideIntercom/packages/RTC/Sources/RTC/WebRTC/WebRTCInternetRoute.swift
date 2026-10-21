import Foundation

public actor WebRTCInternetRoute: RTCCallRoute {
    public let kind: RouteKind = .webRTC
    public let capabilities = RouteCapabilities(
        supportsLocalDiscovery: false,
        supportsOfflineOperation: false,
        supportsRouteManagedMedia: true,
        supportsAppManagedPacketAudio: false,
        supportsReliableApplicationData: true,
        supportsUnreliableApplicationData: true,
        requiresSignaling: true,
        supportedAudioCodecs: [.routeManaged],
        backendName: "Cloudflare Realtime SFU"
    )
    public let mediaOwnership: AudioMediaOwnership = .routeManagedMediaStream
    public nonisolated var events: AsyncStream<RouteEvent> { eventSource.stream }

    private nonisolated let eventSource = EventSource<RouteEvent>()
    private let cloudflareConfigurationProvider: @Sendable (CallStartRequest) -> CloudflareRealtimeConfiguration?
    private let signalingClient: WebRTCSignalingClient
    private let engine: NativeWebRTCEngine
    private var signalingTask: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?
    private var request: CallStartRequest?
    private var remotePeers: [PeerID: PeerDescriptor] = [:]
    private var connecting = false
    private var mediaStarted = false
    private var iceConnected = false
    private var generation = UUID()
    private var localMuted = false
    private let sfuPeer = PeerDescriptor(id: .init(rawValue: "cloudflare-sfu"), displayName: "Cloudflare SFU")

    public init(
        cloudflareConfiguration: CloudflareRealtimeConfiguration,
        signalingClient: WebRTCSignalingClient = CloudflareRealtimeSignalingClient(),
        engine: NativeWebRTCEngine = NativeWebRTCEngine()
    ) {
        self.cloudflareConfigurationProvider = { _ in cloudflareConfiguration }
        self.signalingClient = signalingClient
        self.engine = engine
    }

    public init(
        cloudflareConfigurationProvider: @escaping @Sendable (CallStartRequest) -> CloudflareRealtimeConfiguration?,
        signalingClient: WebRTCSignalingClient = CloudflareRealtimeSignalingClient(),
        engine: NativeWebRTCEngine = NativeWebRTCEngine()
    ) {
        self.cloudflareConfigurationProvider = cloudflareConfigurationProvider
        self.signalingClient = signalingClient
        self.engine = engine
    }

    public init(
        signalingClient: WebRTCSignalingClient = CloudflareRealtimeSignalingClient(),
        engine: NativeWebRTCEngine = NativeWebRTCEngine()
    ) {
        self.cloudflareConfigurationProvider = { _ in nil }
        self.signalingClient = signalingClient
        self.engine = engine
    }

    deinit {
        signalingTask?.cancel()
        engineTask?.cancel()
    }

    public func prepare(_ request: CallStartRequest) async {
        if self.request != nil { await stopConnection() }
        self.request = request
        guard engine.isAvailable else {
            eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: false, reason: "Native WebRTC SDK is unavailable")))
            eventSource.yield(.stateChanged(kind, .failed))
            return
        }
        eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: true)))
        eventSource.yield(.stateChanged(kind, .standby))
    }

    public func startConnection() async {
        guard let request else {
            eventSource.yield(.error(kind, .connectionFailed(kind, "prepare must be called before startConnection")))
            return
        }
        guard engine.isAvailable else {
            eventSource.yield(.stateChanged(kind, .failed))
            eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: false, reason: "Native WebRTC SDK is unavailable")))
            return
        }
        guard let cloudflareConfiguration = cloudflareConfigurationProvider(request) else {
            eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: false, reason: "WebRTC route configuration is unavailable")))
            eventSource.yield(.stateChanged(kind, .failed))
            return
        }
        guard !connecting else { return }
        generation = UUID()
        let generation = generation
        connecting = true
        iceConnected = false
        await engine.prepareLocalAudio(peer: request.localPeer, policy: request.audioPolicy)
        guard self.generation == generation else { return }
        bindSignalingEvents()
        bindEngineEvents()
        eventSource.yield(.stateChanged(kind, .connecting))
        await signalingClient.connect(WebRTCSignalingConnectRequest(call: request, cloudflare: cloudflareConfiguration))
    }

    public func stopConnection() async { await stopConnection(finalState: .disconnected) }

    private func stopConnection(finalState: RouteConnectionState) async {
        generation = UUID()
        let generation = generation
        connecting = false
        iceConnected = false
        mediaStarted = false
        signalingTask?.cancel(); signalingTask = nil
        engineTask?.cancel(); engineTask = nil
        remotePeers.removeAll()
        emitMembers()
        await engine.close()
        guard self.generation == generation else { return }
        await signalingClient.disconnect()
        guard self.generation == generation else { return }
        eventSource.yield(.stateChanged(kind, finalState))
    }

    public func startMedia() async {
        guard connecting else { return }
        mediaStarted = true
        await engine.setLocalAudioEnabled(!localMuted)
        if iceConnected { eventSource.yield(.stateChanged(kind, .mediaReady)) }
    }

    public func stopMedia() async {
        mediaStarted = false
        await engine.setLocalAudioEnabled(false)
    }

    public func sendAudioPacket(_ packet: RTCAudioPacket) async {}

    public func sendApplicationData(_ message: ApplicationDataMessage) async {
        guard connecting else { return }
        await signalingClient.sendApplicationData(message, to: nil)
    }

    public func setLocalMute(_ muted: Bool) async {
        localMuted = muted
        await engine.setLocalAudioEnabled(mediaStarted && !muted)
    }

    public func setOutputMute(_ muted: Bool) async {
        await engine.setOutputMuted(muted)
    }

    private func bindSignalingEvents() {
        let generation = generation
        let events = signalingClient.events
        signalingTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleSignalingEvent(event, generation: generation)
            }
        }
    }

    private func handleSignalingEvent(_ event: WebRTCSignalingEvent, generation: UUID) async {
        guard self.generation == generation, connecting else { return }
        switch event {
        case .connected:
            guard connecting else { return }
            await engine.createPeerConnection(for: sfuPeer)
            guard self.generation == generation else { return }
            if let offer = await engine.makeOffer(for: sfuPeer.id), self.generation == generation {
                await signalingClient.sendOffer(offer, to: sfuPeer.id)
            } else {
                await fail("Could not create WebRTC offer", generation: generation)
            }
        case .members(let peers):
            guard connecting else { return }
            remotePeers = Dictionary(peers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            emitMembers()
        case .disconnected:
            await stopConnection()
        case .remotePeerJoined, .remotePeerLeft:
            break
        case .offer(let offer, let peerID):
            guard connecting, peerID == sfuPeer.id else { return }
            if let answer = await engine.acceptOffer(offer, from: peerID), self.generation == generation {
                await signalingClient.sendAnswer(answer, to: peerID)
            } else {
                await fail("Could not accept WebRTC offer", generation: generation)
            }
        case .answer(let answer, let peerID):
            guard connecting, peerID == sfuPeer.id else { return }
            if await !engine.acceptAnswer(answer, from: peerID) {
                await fail("Could not accept WebRTC answer", generation: generation)
            }
        case .iceCandidate:
            break
        case .receivedApplicationData(let data):
            guard remotePeers[data.peerID] != nil else { return }
            eventSource.yield(.receivedApplicationData(kind, data))
        case .failed(let message):
            await fail(message, generation: generation)
        }
    }

    private func fail(_ message: String, generation: UUID) async {
        guard self.generation == generation else { return }
        eventSource.yield(.error(kind, .connectionFailed(kind, message)))
        await stopConnection(finalState: .failed)
    }

    private func bindEngineEvents() {
        let generation = generation
        let events = engine.events
        engineTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleEngineEvent(event, generation: generation)
            }
        }
    }

    private func handleEngineEvent(_ event: WebRTCEngineEvent, generation: UUID) async {
        guard self.generation == generation, connecting else { return }
        switch event {
        case .localIceCandidate(let candidate, let peerID):
            await signalingClient.sendCandidate(candidate, to: peerID)
        case .receivedApplicationData(let data):
            guard remotePeers[data.peerID] != nil else { return }
            eventSource.yield(.receivedApplicationData(kind, data))
        case .connectionStateChanged(let state):
            iceConnected = state == .connected || state == .mediaReady
            if state == .failed { await fail("WebRTC media connection failed", generation: generation) }
            else { eventSource.yield(.stateChanged(kind, iceConnected && mediaStarted ? .mediaReady : state)) }
        }
    }

    private func emitMembers() {
        let members = remotePeers.values.map {
            CallMemberState(peer: $0, route: kind, isConnected: true)
        }
        eventSource.yield(.membersChanged(kind, members))
        eventSource.yield(.metricsChanged(RouteMetrics(route: kind, activePeerCount: members.count)))
    }
}

public enum WebRTCEngineEvent: Equatable, Sendable {
    case localIceCandidate(WebRTCIceCandidate, peerID: PeerID)
    case receivedApplicationData(ReceivedApplicationData)
    case connectionStateChanged(RouteConnectionState)
}

open class NativeWebRTCEngine: NSObject, @unchecked Sendable {
    private let eventSource = EventSource<WebRTCEngineEvent>()
    public func emit(_ event: WebRTCEngineEvent) { eventSource.yield(event) }
    open var isAvailable: Bool { false }
    open var events: AsyncStream<WebRTCEngineEvent> { eventSource.stream }

    public override init() {}

    open func prepareLocalAudio(peer: PeerDescriptor, policy: RTCAudioPolicy) async {}

    open func createPeerConnection(for peer: PeerDescriptor) async {}
    open func makeOffer(for peerID: PeerID) async -> WebRTCSessionDescription? { nil }

    open func acceptOffer(_ offer: WebRTCSessionDescription, from peerID: PeerID) async -> WebRTCSessionDescription? {
        nil
    }

    open func acceptAnswer(_ answer: WebRTCSessionDescription, from peerID: PeerID) async -> Bool { false }
    open func addCandidate(_ candidate: WebRTCIceCandidate, from peerID: PeerID) async {}
    open func setLocalAudioEnabled(_ enabled: Bool) async {}
    open func setOutputMuted(_ muted: Bool) async {}

    open func closePeerConnection(peerID: PeerID) async {}
    open func close() async {}
}
