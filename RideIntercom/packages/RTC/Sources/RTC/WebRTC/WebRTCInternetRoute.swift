import Foundation

public final class WebRTCInternetRoute: RTCCallRoute, @unchecked Sendable {
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
        backendName: "Cloudflare Realtime SFU/TURN"
    )
    public let mediaOwnership: AudioMediaOwnership = .routeManagedMediaStream
    public var events: AsyncStream<RouteEvent> { eventSource.stream }

    private let eventSource = EventSource<RouteEvent>()
    private let cloudflareConfigurationProvider: @Sendable (CallStartRequest) -> CloudflareRealtimeConfiguration?
    private let signalingClient: WebRTCSignalingClient
    private let engine: NativeWebRTCEngine
    private var signalingTask: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?
    private var request: CallStartRequest?
    private var remotePeers: [PeerID: PeerDescriptor] = [:]

    public init(
        cloudflareConfiguration: CloudflareRealtimeConfiguration,
        signalingClient: WebRTCSignalingClient = CloudflareRealtimeSignalingClient(),
        engine: NativeWebRTCEngine = NativeWebRTCEngine()
    ) {
        self.cloudflareConfigurationProvider = { _ in cloudflareConfiguration }
        self.signalingClient = signalingClient
        self.engine = engine
        bindSignalingEvents()
        bindEngineEvents()
    }

    public init(
        cloudflareConfigurationProvider: @escaping @Sendable (CallStartRequest) -> CloudflareRealtimeConfiguration?,
        signalingClient: WebRTCSignalingClient = CloudflareRealtimeSignalingClient(),
        engine: NativeWebRTCEngine = NativeWebRTCEngine()
    ) {
        self.cloudflareConfigurationProvider = cloudflareConfigurationProvider
        self.signalingClient = signalingClient
        self.engine = engine
        bindSignalingEvents()
        bindEngineEvents()
    }

    public init(
        signalingClient: WebRTCSignalingClient = CloudflareRealtimeSignalingClient(),
        engine: NativeWebRTCEngine = NativeWebRTCEngine()
    ) {
        self.cloudflareConfigurationProvider = { _ in nil }
        self.signalingClient = signalingClient
        self.engine = engine
        bindSignalingEvents()
        bindEngineEvents()
    }

    deinit {
        signalingTask?.cancel()
        engineTask?.cancel()
    }

    public func prepare(_ request: CallStartRequest) async {
        self.request = request
        guard engine.isAvailable else {
            eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: false, reason: "Native WebRTC SDK is unavailable")))
            eventSource.yield(.stateChanged(kind, .failed))
            return
        }
        await engine.prepareLocalAudio(peer: request.localPeer, policy: request.audioPolicy)
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
        eventSource.yield(.stateChanged(kind, .connecting))
        await signalingClient.connect(WebRTCSignalingConnectRequest(call: request, cloudflare: cloudflareConfiguration))
    }

    public func stopConnection() async {
        await signalingClient.disconnect()
        await engine.close()
        remotePeers.removeAll()
        eventSource.yield(.stateChanged(kind, .disconnected))
    }

    public func startMedia() async {
        await engine.setLocalAudioEnabled(true)
        eventSource.yield(.stateChanged(kind, .mediaReady))
    }

    public func stopMedia() async {
        await engine.setLocalAudioEnabled(false)
    }

    public func sendAudioPacket(_ packet: RTCAudioPacket) async {}

    public func sendApplicationData(_ message: ApplicationDataMessage) async {
        if await engine.sendApplicationData(message) == false {
            await signalingClient.sendApplicationData(message, to: nil)
        }
    }

    public func setLocalMute(_ muted: Bool) async {
        await engine.setLocalAudioEnabled(!muted)
    }

    public func setOutputMute(_ muted: Bool) async {
        await engine.setOutputMuted(muted)
    }

    private func bindSignalingEvents() {
        signalingTask = Task { [weak self] in
            guard let self else { return }
            for await event in signalingClient.events {
                await self.handleSignalingEvent(event)
            }
        }
    }

    private func handleSignalingEvent(_ event: WebRTCSignalingEvent) async {
        switch event {
        case .connected:
            eventSource.yield(.stateChanged(kind, .connected))
        case .disconnected:
            eventSource.yield(.stateChanged(kind, .disconnected))
        case .remotePeerJoined(let peer):
            remotePeers[peer.id] = peer
            await engine.createPeerConnection(for: peer)
            if let offer = await engine.makeOffer(for: peer.id) {
                await signalingClient.sendOffer(offer, to: peer.id)
            }
            emitMembers()
        case .remotePeerLeft(let peerID):
            remotePeers.removeValue(forKey: peerID)
            await engine.closePeerConnection(peerID: peerID)
            emitMembers()
        case .offer(let offer, let peerID):
            if remotePeers[peerID] == nil {
                let peer = PeerDescriptor(id: peerID, displayName: peerID.rawValue)
                remotePeers[peerID] = peer
                await engine.createPeerConnection(for: peer)
                emitMembers()
            }
            if let answer = await engine.acceptOffer(offer, from: peerID) {
                await signalingClient.sendAnswer(answer, to: peerID)
            }
        case .answer(let answer, let peerID):
            await engine.acceptAnswer(answer, from: peerID)
        case .iceCandidate(let candidate, let peerID):
            await engine.addCandidate(candidate, from: peerID)
        case .receivedApplicationData(let data):
            eventSource.yield(.receivedApplicationData(kind, data))
        case .failed(let message):
            eventSource.yield(.error(kind, .connectionFailed(kind, message)))
            eventSource.yield(.stateChanged(kind, .failed))
        }
    }

    private func bindEngineEvents() {
        engineTask = Task { [weak self] in
            guard let self else { return }
            for await event in engine.events {
                await self.handleEngineEvent(event)
            }
        }
    }

    private func handleEngineEvent(_ event: WebRTCEngineEvent) async {
        switch event {
        case .localIceCandidate(let candidate, let peerID):
            await signalingClient.sendCandidate(candidate, to: peerID)
        case .receivedApplicationData(let data):
            eventSource.yield(.receivedApplicationData(kind, data))
        case .connectionStateChanged(let state):
            eventSource.yield(.stateChanged(kind, state))
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

open class NativeWebRTCEngine: NSObject {
    open var isAvailable: Bool { false }
    open var events: AsyncStream<WebRTCEngineEvent> { AsyncStream { $0.finish() } }

    public override init() {}

    open func prepareLocalAudio(peer: PeerDescriptor, policy: RTCAudioPolicy) async {}

    open func createPeerConnection(for peer: PeerDescriptor) async {}
    open func makeOffer(for peerID: PeerID) async -> WebRTCSessionDescription? { nil }

    open func acceptOffer(_ offer: WebRTCSessionDescription, from peerID: PeerID) async -> WebRTCSessionDescription? {
        nil
    }

    open func acceptAnswer(_ answer: WebRTCSessionDescription, from peerID: PeerID) async {}
    open func addCandidate(_ candidate: WebRTCIceCandidate, from peerID: PeerID) async {}
    open func setLocalAudioEnabled(_ enabled: Bool) async {}
    open func setOutputMuted(_ muted: Bool) async {}

    open func sendApplicationData(_ message: ApplicationDataMessage) async -> Bool {
        false
    }

    open func closePeerConnection(peerID: PeerID) async {}
    open func close() async {}
}
