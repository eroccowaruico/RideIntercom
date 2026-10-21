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
    private var connecting = false
    private var mediaStarted = false
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
        connecting = true
        eventSource.yield(.stateChanged(kind, .connecting))
        await signalingClient.connect(WebRTCSignalingConnectRequest(call: request, cloudflare: cloudflareConfiguration))
    }

    public func stopConnection() async {
        connecting = false
        mediaStarted = false
        await signalingClient.disconnect()
        await engine.close()
        remotePeers.removeAll()
        eventSource.yield(.stateChanged(kind, .disconnected))
    }

    public func startMedia() async {
        guard connecting else { return }
        mediaStarted = true
        await engine.setLocalAudioEnabled(!localMuted)
        eventSource.yield(.stateChanged(kind, .mediaReady))
    }

    public func stopMedia() async {
        mediaStarted = false
        await engine.setLocalAudioEnabled(false)
    }

    public func sendAudioPacket(_ packet: RTCAudioPacket) async {}

    public func sendApplicationData(_ message: ApplicationDataMessage) async {
        if await engine.sendApplicationData(message) == false {
            await signalingClient.sendApplicationData(message, to: nil)
        }
    }

    public func setLocalMute(_ muted: Bool) async {
        localMuted = muted
        await engine.setLocalAudioEnabled(mediaStarted && !muted)
    }

    public func setOutputMute(_ muted: Bool) async {
        await engine.setOutputMuted(muted)
    }

    private func bindSignalingEvents() {
        let events = signalingClient.events
        signalingTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleSignalingEvent(event)
            }
        }
    }

    private func handleSignalingEvent(_ event: WebRTCSignalingEvent) async {
        switch event {
        case .connected:
            guard connecting else { return }
            await engine.createPeerConnection(for: sfuPeer)
            if let offer = await engine.makeOffer(for: sfuPeer.id), connecting {
                await signalingClient.sendOffer(offer, to: sfuPeer.id)
            } else if connecting {
                await engine.close(); connecting = false
                eventSource.yield(.stateChanged(kind, .failed))
            }
        case .members(let peers):
            guard connecting else { return }
            remotePeers = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0) })
            emitMembers()
        case .disconnected:
            connecting = false
            await engine.close()
            remotePeers.removeAll(); emitMembers()
            eventSource.yield(.stateChanged(kind, .disconnected))
        case .remotePeerJoined, .remotePeerLeft:
            break
        case .offer(let offer, let peerID):
            guard connecting, peerID == sfuPeer.id else { return }
            if let answer = await engine.acceptOffer(offer, from: peerID), connecting {
                await signalingClient.sendAnswer(answer, to: peerID)
            }
        case .answer(let answer, let peerID):
            guard connecting, peerID == sfuPeer.id else { return }
            await engine.acceptAnswer(answer, from: peerID)
        case .iceCandidate:
            break
        case .receivedApplicationData(let data):
            eventSource.yield(.receivedApplicationData(kind, data))
        case .failed(let message):
            connecting = false
            await engine.close()
            remotePeers.removeAll(); emitMembers()
            eventSource.yield(.error(kind, .connectionFailed(kind, message)))
            eventSource.yield(.stateChanged(kind, .failed))
        }
    }

    private func bindEngineEvents() {
        let events = engine.events
        engineTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleEngineEvent(event)
            }
        }
    }

    private func handleEngineEvent(_ event: WebRTCEngineEvent) async {
        guard connecting else { return }
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
