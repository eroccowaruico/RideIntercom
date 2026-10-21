import Foundation

/// Keeps usable links alive. Automatic routing adds a second path; it never
/// disconnects one group of members merely because another path became ready.
public actor RouteManager: CallSession {
    nonisolated public var events: AsyncStream<CallSessionEvent> { eventSource.stream }
    private let eventSource = EventSource<CallSessionEvent>(isTransient: { $0.isTransient })
    private let routes: [RouteKind: RTCCallRoute]
    private var configuration: CallRouteConfiguration
    private let runtimeStatusPolicy: RTCRuntimeStatusPolicy
    private var generation = UUID()
    private var request: CallStartRequest?
    private var routeTasks: [Task<Void, Never>] = []
    private var timer: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var routeStates: [RouteKind: RouteConnectionState] = [:]
    private var routeAvailabilities: [RouteKind: RouteAvailability] = [:]
    private var routeMembers: [RouteKind: Set<PeerID>] = [:]
    private var started: Set<RouteKind> = []
    private var retries: [RouteKind: (deadline: TimeInterval, delay: TimeInterval)] = [:]
    private var activeRoute: RouteKind?
    private var mediaRoute: RouteKind? { activeRoute }
    private var availableRoutes: Set<RouteKind> = []
    private var connectionState: CallConnectionState = .idle
    private var isMediaStarted = false
    private var localMute = false
    private var outputMute = false
    private var relay: GroupRelay?
    private var receiveBuffer = PacketAudioReceiveBuffer()
    private var memberSnapshot: [CallMemberState] = []
    private var observedPaths: [PeerID: RTCObservedPeerPath] = [:]
    private var memberRoutes: [PeerID: RouteKind] = [:]
    private var lastPresence: TimeInterval = 0
    private var lastRuntimeStatus: TimeInterval = 0
    private var runtimePackageReports: [RTCRuntimePackageReport] = []

    public init(routes: [RTCCallRoute], configuration: CallRouteConfiguration = .init(),
                runtimeStatusPolicy: RTCRuntimeStatusPolicy = .init()) {
        self.routes = Dictionary(uniqueKeysWithValues: routes.map { ($0.kind, $0) })
        self.configuration = configuration.normalized()
        self.runtimeStatusPolicy = runtimeStatusPolicy
    }
    public init(routeFactories: [AnyRouteFactory], configuration: CallRouteConfiguration = .init(),
                runtimeStatusPolicy: RTCRuntimeStatusPolicy = .init()) {
        self.init(routes: routeFactories.map { $0.make() }, configuration: configuration, runtimeStatusPolicy: runtimeStatusPolicy)
    }
    deinit { routeTasks.forEach { $0.cancel() }; timer?.cancel(); fallbackTask?.cancel() }

    public func prepare(_ request: CallStartRequest) async {
        if self.request != nil { await stopConnection() }
        generation = UUID()
        let token = generation
        self.request = request
        configuration = request.configuration.normalized()
        relay = GroupRelay(request: request)
        observedPaths = [:]; eventSource.resetDiagnostics()
        receiveBuffer.reset(); memberSnapshot = []; memberRoutes = [:]; routeMembers = [:]
        routeStates = [:]; routeAvailabilities = [:]; started = []; retries = [:]
        availableRoutes = []; activeRoute = nil; isMediaStarted = false
        emitState(.preparing)
        let enabled = configuration.enabledRoutes.compactMap { routes[$0] }
        guard !enabled.isEmpty else { emit(.error(.noEnabledRoute)); emitState(.failed); return }
        routeTasks = enabled.map { route in
            let events = route.events
            return Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event, generation: token)
                }
            }
        }
        for route in enabled {
            await route.prepare(request)
            guard generation == token else { return }
        }
        emitRouteSnapshot()
    }
    public func startConnection() async {
        guard request != nil else { return }
        let token = generation
        emitState(.connecting)
        await start(configuration.preferredRoute)
        guard generation == token else { return }
        if configuration.selectionMode != .singleRoute {
            let delay = max(0, configuration.fallbackDelay)
            fallbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.startRemaining(generation: token)
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled else { return }
                await self?.tick(generation: token)
            }
        }
        await broadcast(.presence)
        await sendRuntimeStatus(reason: .connectionStarted)
    }
    private func start(_ kind: RouteKind) async {
        guard configuration.enabledRoutes.contains(kind), let route = routes[kind], !started.contains(kind) else { return }
        started.insert(kind); routeStates[kind] = .connecting
        await route.startConnection()
    }
    private func startRemaining(generation token: UUID) async {
        guard generation == token, request != nil else { return }
        for kind in configuration.enabledRoutes.sorted(by: { $0.rawValue < $1.rawValue }) {
            await start(kind)
            guard generation == token else { return }
        }
    }
    public func stopConnection() async {
        await broadcast(.leave)
        generation = UUID()
        let token = generation
        timer?.cancel(); timer = nil; fallbackTask?.cancel(); fallbackTask = nil
        routeTasks.forEach { $0.cancel() }; routeTasks = []
        observedPaths = [:]; eventSource.resetDiagnostics()
        request = nil; relay = nil; started = []; retries = [:]; availableRoutes = []
        activeRoute = nil; isMediaStarted = false; receiveBuffer.reset()
        memberSnapshot = []; memberRoutes = [:]; routeMembers = [:]
        for route in routes.values {
            await route.stopMedia(); await route.stopConnection()
            guard generation == token else { return }
        }
        emit(.membersChanged([])); emitRouteSnapshot(); emitState(.disconnected)
    }
    public func startMedia() async {
        guard request != nil else { return }
        isMediaStarted = true
        await sendRuntimeStatus(reason: .mediaStarted)
        updateState()
    }
    public func stopMedia() async {
        isMediaStarted = false; receiveBuffer.reset()
        // Relay remains active while this device changes its microphone/output.
        await sendRuntimeStatus(reason: .mediaStopped)
        updateState()
    }
    public func sendAudioPacket(_ packet: RTCAudioPacket) async {
        guard isMediaStarted, !localMute, packet.payload.count <= 8192 else { return }
        await broadcast(.audio(packet))
    }
    public func sendApplicationData(_ message: ApplicationDataMessage) async {
        guard message.namespace != GroupRelay.namespace, message.payload.count <= 12000 else { return }
        await broadcast(.application(message))
    }
    public func setLocalMute(_ muted: Bool) async {
        localMute = muted
        await sendRuntimeStatus(reason: .localControlsChanged)
    }
    public func setOutputMute(_ muted: Bool) async {
        outputMute = muted
        await sendRuntimeStatus(reason: .localControlsChanged)
    }
    public func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) async {
        runtimePackageReports = reports.sorted { ($0.package, $0.kind) < ($1.package, $1.kind) }
        await sendRuntimeStatus(reason: .packageReportsChanged)
    }
    private func broadcast(_ body: RelayBody) async {
        guard let data = try? relay?.make(body, now: Date.timeIntervalSinceReferenceDate), data.count <= 32768 else { return }
        let skipInternet: Bool
        if case .audio = body {
            skipInternet = routeMembers[.webRTC, default: []].isSubset(of: routeMembers[.multipeer, default: []]) && !routeMembers[.multipeer, default: []].isEmpty
        } else { skipInternet = false }
        await forward(data, delivery: body.delivery, excluding: skipInternet ? .webRTC : nil)
    }
    private func forward(_ data: Data, delivery: ApplicationDataDelivery, excluding: RouteKind? = nil) async {
        let token = generation
        let message = ApplicationDataMessage(namespace: GroupRelay.namespace, payload: data, delivery: delivery)
        for kind in started.sorted(by: { $0.rawValue < $1.rawValue }) where kind != excluding {
            await routes[kind]?.sendApplicationData(message)
            guard generation == token else { return }
        }
    }
    private func handle(_ event: RouteEvent, generation token: UUID) async {
        guard generation == token, request != nil else { return }
        switch event {
        case .stateChanged(let kind, let state):
            routeStates[kind] = state
            if kind == .webRTC { relay?.internetReady = state == .mediaReady }
            if [.connected, .authenticated, .mediaReady].contains(state) {
                availableRoutes.insert(kind); retries[kind] = nil
                await broadcast(.presence)
            } else if state == .failed || state == .disconnected {
                availableRoutes.remove(kind); routeMembers[kind] = []
                if started.contains(kind) {
                    let delay = min(30, (retries[kind]?.delay ?? 1) * 2)
                    retries[kind] = (Date.timeIntervalSinceReferenceDate + delay, delay)
                }
            }
            updateState(); emitRouteSnapshot()
        case .availabilityChanged(let availability):
            routeAvailabilities[availability.route] = availability
            emit(.routeAvailabilityChanged([availability]))
        case .membersChanged(let kind, let members):
            routeMembers[kind] = Set(members.filter(\.isConnected).map { $0.peer.id })
            await broadcast(.presence)
        case .receivedApplicationData(let kind, let data):
            guard started.contains(kind), routeMembers[kind, default: []].contains(data.peerID),
                  data.message.namespace == GroupRelay.namespace,
                  let result = relay?.receive(data.message.payload, from: data.peerID, now: Date.timeIntervalSinceReferenceDate) else { return }
            if result.didRestart {
                receiveBuffer.removePeer(result.peer.id)
                memberSnapshot.removeAll { $0.peer.id == result.peer.id }
                emit(.membersChanged(memberSnapshot))
            }
            observedPaths[result.peer.id] = .init(peerID: result.peer.id, route: kind, path: result.path, observedAt: Date().timeIntervalSince1970)
            memberRoutes[result.peer.id] = kind
            updateMembers()
            switch result.body {
            case .audio(let packet):
                if isMediaStarted { receiveBuffer.enqueue(.init(received: .init(peerID: result.peer.id, packet: packet)), receivedAt: Date.timeIntervalSinceReferenceDate) }
            case .application(let message): emit(.receivedApplicationData(.init(peerID: result.peer.id, message: message)))
            case .presence, .leave: break
            }
            // SFU already fans out to every subscriber. Local links may be a chain.
            if let bytes = result.forward {
                var excluded: RouteKind? = kind == .webRTC ? .webRTC : nil
                if case .audio = result.body, kind == .multipeer {
                    // One ready gateway per directly connected Local neighborhood.
                    // During topology convergence duplicate suppression still protects playback.
                    var candidates = (relay?.internetGateways(now: Date.timeIntervalSinceReferenceDate) ?? []).intersection(routeMembers[.multipeer, default: []])
                    if relay?.internetReady == true, let id = request?.localPeer.id { candidates.insert(id) }
                    let elected = candidates.min { $0.rawValue < $1.rawValue }
                    let originHasInternet = relay?.internetGateways(now: Date.timeIntervalSinceReferenceDate).contains(result.peer.id) == true
                    if originHasInternet || elected != request?.localPeer.id { excluded = .webRTC }
                }
                await forward(bytes, delivery: result.body.delivery, excluding: excluded)
            }
        case .receivedAudioPacket: break // Audio uses the authenticated group envelope on every path.
        case .metricsChanged(let metrics): emit(.metricsChanged(metrics))
        case .error(_, let error): emit(.error(error))
        }
    }
    private func tick(generation token: UUID) async {
        guard generation == token, let request else { return }
        let now = Date.timeIntervalSinceReferenceDate
        for packet in receiveBuffer.drain(now: now).readyPackets { emit(.receivedAudioPacket(packet)) }
        if now - lastPresence >= 2 {
            lastPresence = now
            await broadcast(.presence)
            guard generation == token else { return }
            updateMembers()
        }
        for (kind, retry) in retries where now >= retry.deadline {
            retries[kind]?.deadline = now + retry.delay
            started.remove(kind)
            await routes[kind]?.prepare(request)
            guard generation == token else { return }
            await start(kind)
            guard generation == token else { return }
        }
        if let interval = runtimeStatusPolicy.periodicInterval, now - lastRuntimeStatus >= interval {
            lastRuntimeStatus = now
            await sendRuntimeStatus(reason: .periodic)
        }
    }
    private func updateMembers() {
        let next = (relay?.members(now: Date.timeIntervalSinceReferenceDate) ?? []).map {
            CallMemberState(peer: $0, route: memberRoutes[$0.id], isConnected: true)
        }
        guard next != memberSnapshot else { return }
        let departed = Set(memberSnapshot.map { $0.peer.id }).subtracting(next.map { $0.peer.id })
        for peer in departed { receiveBuffer.removePeer(peer); memberRoutes[peer] = nil; observedPaths[peer] = nil }
        memberSnapshot = next
        emit(.membersChanged(next)); updateState()
    }
    private func updateState() {
        let live = availableRoutes.intersection(started)
        activeRoute = live.contains(configuration.preferredRoute) ? configuration.preferredRoute : live.sorted { $0.rawValue < $1.rawValue }.first
        let state: CallConnectionState = !memberSnapshot.isEmpty ? (isMediaStarted ? .mediaReady : .connected) : (live.isEmpty && !retries.isEmpty ? .reconnecting : .connecting)
        if connectionState != state { emitState(state) }
    }
    private func emitRouteSnapshot() { emit(.routeChanged(routeSnapshot())) }
    private func routeSnapshot() -> ActiveRouteSnapshot {
        ActiveRouteSnapshot(activeRoute: activeRoute, mediaRoute: mediaRoute, availableRoutes: availableRoutes,
                            isHandoverInProgress: !retries.isEmpty && availableRoutes.isEmpty)
    }
    private func sendRuntimeStatus(reason: RTCRuntimeStatusReason) async {
        let token = generation
        let network = await networkDiagnostics()
        guard token == generation else { return }
        emit(.networkDiagnosticsChanged(network))
        guard runtimeStatusPolicy.isAutomaticBroadcastEnabled else { return }
        var status = makeRuntimeStatus(reason: reason)
        if let report = try? RTCRuntimePackageReport.json(package: "RTC", kind: "network", payload: network) {
            status.packageReports.append(report)
        }
        guard let message = try? RTCRuntimeStatusTransport.makeMessage(status, delivery: .unreliable) else { return }
        await sendApplicationData(message)
    }
    public func networkDiagnostics() async -> RTCNetworkDiagnostics {
        let token = generation
        var diagnostics: [RTCRouteNetworkDiagnostics] = []
        for kind in started.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let route = routes[kind] { diagnostics.append(await route.networkDiagnostics()) }
            guard generation == token else { return .init(generatedAt: Date().timeIntervalSince1970, eventDrops: .init(), routes: [], peers: []) }
        }
        let now = Date().timeIntervalSince1970
        let paths = observedPaths.values.filter { path in
            now - path.observedAt < GroupRelay.presenceLifetime && availableRoutes.contains(path.route)
                && path.path.dropLast().last.map { routeMembers[path.route, default: []].contains($0) } == true
        }
        return .init(generatedAt: now, eventDrops: eventSource.report, routes: diagnostics,
                     peers: paths.sorted { $0.peerID.rawValue < $1.peerID.rawValue })
    }

    private func makeRuntimeStatus(reason: RTCRuntimeStatusReason) -> RTCRuntimeStatus {
        let request = request ?? CallStartRequest(
            sessionID: "",
            localPeer: PeerDescriptor(id: PeerID(rawValue: ""), displayName: ""),
            configuration: configuration
        )
        return RTCRuntimeStatus(
            reason: reason,
            generatedAt: Date().timeIntervalSince1970,
            sessionID: request.sessionID,
            localPeer: request.localPeer,
            expectedPeers: request.expectedPeers,
            connectionState: connectionState,
            isMediaStarted: isMediaStarted,
            localMute: localMute,
            outputMute: outputMute,
            routeSnapshot: routeSnapshot(),
            routes: routes.values
                .sorted { $0.kind.rawValue < $1.kind.rawValue }
                .map { route in
                    RTCRouteRuntimeStatus(
                        route: route.kind,
                        state: routeStates[route.kind] ?? .idle,
                        isAvailable: availableRoutes.contains(route.kind),
                        availabilityReason: routeAvailabilities[route.kind]?.reason,
                        capabilities: route.capabilities,
                        mediaOwnership: route.mediaOwnership,
                        isActiveRoute: activeRoute == route.kind,
                        isMediaRoute: mediaRoute == route.kind,
                        selectedAudioCodec: selectedAudioCodec(for: route, request: request)
                    )
                },
            packageReports: runtimePackageReports,
            configuration: configuration,
            audioPolicy: request.audioPolicy
        )
    }

    private func selectedAudioCodec(
        for route: RTCCallRoute,
        request: CallStartRequest
    ) -> RTCAudioCodecIdentifier? {
        let supported = route.capabilities.supportedAudioCodecs
        if route.mediaOwnership == .routeManagedMediaStream {
            return supported.first ?? .routeManaged
        }
        return request.audioPolicy.preferredCodecs.first { supported.contains($0) } ?? supported.first
    }

    private func emitState(_ state: CallConnectionState) {
        connectionState = state
        emit(.stateChanged(state))
    }

    private func emit(_ event: CallSessionEvent) {
        eventSource.yield(event)
    }
}
