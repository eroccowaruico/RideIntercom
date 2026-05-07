import Foundation

public final class RouteManager: CallSession, @unchecked Sendable {
    public var events: AsyncStream<CallSessionEvent> { eventSource.stream }

    private let eventSource = EventSource<CallSessionEvent>()
    private var routes: [RouteKind: RTCCallRoute]
    private var routeTasks: [Task<Void, Never>] = []
    private var configuration: CallRouteConfiguration
    private var request: CallStartRequest?
    private var activeRoute: RouteKind?
    private var mediaRoute: RouteKind?
    private var availableRoutes: Set<RouteKind> = []
    private var isMediaStarted = false
    private var connectionState: CallConnectionState = .idle
    private var routeStates: [RouteKind: RouteConnectionState] = [:]
    private var routeAvailabilities: [RouteKind: RouteAvailability] = [:]
    private var localMute = false
    private var outputMute = false
    private var runtimePackageReports: [RTCRuntimePackageReport] = []
    private var fallbackTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var handoverTask: Task<Void, Never>?
    private var runtimeStatusTask: Task<Void, Never>?
    private let runtimeStatusPolicy: RTCRuntimeStatusPolicy

    public init(
        routes: [RTCCallRoute],
        configuration: CallRouteConfiguration = CallRouteConfiguration(),
        runtimeStatusPolicy: RTCRuntimeStatusPolicy = RTCRuntimeStatusPolicy()
    ) {
        let normalizedConfiguration = configuration.normalized()
        self.configuration = normalizedConfiguration
        self.runtimeStatusPolicy = runtimeStatusPolicy
        self.routes = Dictionary(
            uniqueKeysWithValues: routes
                .filter { normalizedConfiguration.enabledRoutes.contains($0.kind) }
                .map { ($0.kind, $0) }
        )
        self.routeStates = Dictionary(uniqueKeysWithValues: self.routes.keys.map { ($0, .idle) })
        bindRouteEvents()
    }

    public convenience init(
        routeFactories: [AnyRouteFactory],
        configuration: CallRouteConfiguration = CallRouteConfiguration(),
        runtimeStatusPolicy: RTCRuntimeStatusPolicy = RTCRuntimeStatusPolicy()
    ) {
        let normalizedConfiguration = configuration.normalized()
        self.init(
            routes: routeFactories
                .filter { normalizedConfiguration.enabledRoutes.contains($0.kind) }
                .map { $0.make() },
            configuration: normalizedConfiguration,
            runtimeStatusPolicy: runtimeStatusPolicy
        )
    }

    deinit {
        routeTasks.forEach { $0.cancel() }
        fallbackTask?.cancel()
        restoreTask?.cancel()
        handoverTask?.cancel()
        runtimeStatusTask?.cancel()
    }

    public func prepare(_ request: CallStartRequest) async {
        let normalizedRequest = CallStartRequest(
            sessionID: request.sessionID,
            localPeer: request.localPeer,
            expectedPeers: request.expectedPeers,
            credential: request.credential,
            configuration: request.configuration.normalized(),
            audioPolicy: request.audioPolicy
        )

        self.request = normalizedRequest
        self.configuration = normalizedRequest.configuration
        self.routes = routes.filter { configuration.enabledRoutes.contains($0.key) }
        self.routeStates = Dictionary(uniqueKeysWithValues: self.routes.keys.map { ($0, .idle) })
        self.routeAvailabilities.removeAll()
        self.availableRoutes.removeAll()
        bindRouteEvents()
        emitState(.preparing)

        guard !routes.isEmpty else {
            emit(.error(.noEnabledRoute))
            emitState(.failed)
            return
        }

        for route in routes.values {
            await route.prepare(normalizedRequest)
        }

        emitRouteSnapshot()
    }

    public func startConnection() async {
        guard let request else {
            emit(.error(.connectionFailed(configuration.preferredRoute, "prepare must be called before startConnection")))
            return
        }

        emitState(.connecting)

        if configuration.keepsPreferredRouteInStandby {
            for standbyKind in configuration.enabledRoutes where standbyKind != configuration.preferredRoute {
                await routes[standbyKind]?.startConnection()
            }
        }

        guard let preferredRoute = routes[configuration.preferredRoute] else {
            emit(.error(.routeUnavailable(configuration.preferredRoute)))
            await activateFirstAvailableRoute(excluding: nil)
            return
        }

        activeRoute = preferredRoute.kind
        mediaRoute = preferredRoute.kind
        emitRouteSnapshot()
        await preferredRoute.startConnection()
        scheduleFallbackIfNeeded(for: request)
        await sendRuntimeStatus(reason: .connectionStarted)
        startPeriodicRuntimeStatusBroadcast()
    }

    public func stopConnection() async {
        await sendRuntimeStatus(reason: .connectionStopping)
        cancelTimers()
        for route in routes.values {
            await route.stopMedia()
            await route.stopConnection()
        }
        activeRoute = nil
        mediaRoute = nil
        availableRoutes.removeAll()
        isMediaStarted = false
        emitRouteSnapshot()
        emitState(.disconnected)
    }

    public func startMedia() async {
        guard !isMediaStarted else { return }
        isMediaStarted = true
        if let route = activeRoute.flatMap({ routes[$0] }) {
            mediaRoute = route.kind
            await route.startMedia()
            emitRouteSnapshot()
            await sendRuntimeStatus(reason: .mediaStarted)
        }
    }

    public func stopMedia() async {
        guard isMediaStarted else { return }
        isMediaStarted = false
        if let route = mediaRoute.flatMap({ routes[$0] }) {
            await route.stopMedia()
        }
        mediaRoute = activeRoute
        emitRouteSnapshot()
        await sendRuntimeStatus(reason: .mediaStopped)
    }

    public func sendAudioPacket(_ packet: RTCAudioPacket) async {
        guard let route = mediaRoute.flatMap({ routes[$0] }), route.capabilities.supportsAppManagedPacketAudio else { return }
        await route.sendAudioPacket(packet)
    }

    public func sendApplicationData(_ message: ApplicationDataMessage) async {
        guard let route = activeRoute.flatMap({ routes[$0] }) else { return }
        guard route.supports(message.delivery) else {
            emit(.error(.unsupportedApplicationDataDelivery(route.kind, message.delivery)))
            return
        }
        await route.sendApplicationData(message)
    }

    public func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) async {
        runtimePackageReports = reports.sorted {
            if $0.package != $1.package {
                return $0.package < $1.package
            }
            return $0.kind < $1.kind
        }
        await sendRuntimeStatus(reason: .packageReportsChanged)
    }

    public func setLocalMute(_ muted: Bool) async {
        localMute = muted
        for route in routes.values {
            await route.setLocalMute(muted)
        }
        await sendRuntimeStatus(reason: .localControlsChanged)
    }

    public func setOutputMute(_ muted: Bool) async {
        outputMute = muted
        for route in routes.values {
            await route.setOutputMute(muted)
        }
        await sendRuntimeStatus(reason: .localControlsChanged)
    }

    private func bindRouteEvents() {
        routeTasks.forEach { $0.cancel() }
        routeTasks = routes.values.map { route in
            Task { [weak self, weak route] in
                guard let route else { return }
                for await event in route.events {
                    await self?.handle(event)
                }
            }
        }
    }

    private func handle(_ event: RouteEvent) async {
        switch event {
        case .stateChanged(let kind, let state):
            await handleRouteState(kind: kind, state: state)
        case .availabilityChanged(let availability):
            routeAvailabilities[availability.route] = availability
            if availability.isAvailable {
                availableRoutes.insert(availability.route)
            } else {
                availableRoutes.remove(availability.route)
            }
            emit(.routeAvailabilityChanged([availability]))
            emitRouteSnapshot()
            await sendRuntimeStatus(reason: .routeChanged)
        case .membersChanged(_, let members):
            emit(.membersChanged(members))
            await sendRuntimeStatus(reason: .routeChanged)
        case .receivedApplicationData(_, let data):
            emit(.receivedApplicationData(data))
        case .receivedAudioPacket(_, let packet):
            emit(.receivedAudioPacket(packet))
        case .metricsChanged(let metrics):
            emit(.metricsChanged(metrics))
        case .error(_, let error):
            emit(.error(error))
            await sendRuntimeStatus(reason: .routeChanged)
        }
    }

    private func handleRouteState(kind: RouteKind, state: RouteConnectionState) async {
        routeStates[kind] = state
        switch state {
        case .connected, .authenticated, .mediaReady:
            availableRoutes.insert(kind)
            if activeRoute == kind {
                fallbackTask?.cancel()
                fallbackTask = nil
                emitState(state == .mediaReady ? .mediaReady : .connected)
            } else if shouldRestorePreferredRoute(from: kind) {
                scheduleRestoreToPreferredRoute()
            }
        case .failed, .disconnected:
            availableRoutes.remove(kind)
            if activeRoute == kind {
                await failover(from: kind)
            }
        default:
            break
        }
        emitRouteSnapshot()
        await sendRuntimeStatus(reason: .routeChanged)
    }

    private func shouldRestorePreferredRoute(from kind: RouteKind) -> Bool {
        configuration.selectionMode == .automaticFallbackAndRestore
            && kind == configuration.preferredRoute
            && activeRoute != configuration.preferredRoute
            && routes[kind] != nil
    }

    private func scheduleFallbackIfNeeded(for request: CallStartRequest) {
        fallbackTask?.cancel()
        guard configuration.selectionMode != .singleRoute,
              configuration.enabledRoutes.count > 1,
              activeRoute == configuration.preferredRoute else { return }

        fallbackTask = Task { [weak self] in
            let delay = UInt64(max(0, request.configuration.fallbackDelay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.activateFallbackRoute()
        }
    }

    private func scheduleRestoreToPreferredRoute() {
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            guard let self else { return }
            let delay = UInt64(max(0, configuration.restoreProbeDuration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self.handover(to: self.configuration.preferredRoute)
        }
    }

    private func activateFallbackRoute() async {
        guard activeRoute == configuration.preferredRoute else { return }
        await activateFirstAvailableRoute(excluding: activeRoute)
    }

    private func activateFirstAvailableRoute(excluding excludedRoute: RouteKind?) async {
        guard let nextRoute = routes.values.first(where: { $0.kind != excludedRoute }) else {
            emitState(.failed)
            emit(.error(.noEnabledRoute))
            return
        }
        await handover(to: nextRoute.kind)
    }

    private func failover(from routeKind: RouteKind) async {
        guard configuration.selectionMode != .singleRoute else {
            emitState(.failed)
            return
        }
        await activateFirstAvailableRoute(excluding: routeKind)
    }

    private func handover(to nextKind: RouteKind) async {
        guard let nextRoute = routes[nextKind], activeRoute != nextKind else { return }
        let previousKind = activeRoute
        let previousRoute = previousKind.flatMap { routes[$0] }

        activeRoute = nextKind
        emitRouteSnapshot(isHandoverInProgress: true)
        await sendRuntimeStatus(reason: .routeChanged)
        await nextRoute.startConnection()

        if isMediaStarted {
            await nextRoute.startMedia()
            mediaRoute = nextKind
            let delay = UInt64(max(0, configuration.handoverFadeDuration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            await previousRoute?.stopMedia()
        }

        if previousKind != configuration.preferredRoute || !configuration.keepsFallbackRouteWarm {
            await previousRoute?.stopConnection()
        }

        emitRouteSnapshot(isHandoverInProgress: false)
        await sendRuntimeStatus(reason: .routeChanged)
    }

    private func cancelTimers() {
        fallbackTask?.cancel()
        restoreTask?.cancel()
        handoverTask?.cancel()
        runtimeStatusTask?.cancel()
        fallbackTask = nil
        restoreTask = nil
        handoverTask = nil
        runtimeStatusTask = nil
    }

    private func emitRouteSnapshot(isHandoverInProgress: Bool = false) {
        emit(.routeChanged(routeSnapshot(isHandoverInProgress: isHandoverInProgress)))
    }

    private func routeSnapshot(isHandoverInProgress: Bool = false) -> ActiveRouteSnapshot {
        ActiveRouteSnapshot(
            activeRoute: activeRoute,
            mediaRoute: mediaRoute,
            availableRoutes: availableRoutes,
            isHandoverInProgress: isHandoverInProgress
        )
    }

    private func startPeriodicRuntimeStatusBroadcast() {
        runtimeStatusTask?.cancel()
        guard runtimeStatusPolicy.isAutomaticBroadcastEnabled,
              let interval = runtimeStatusPolicy.periodicInterval,
              interval > 0 else { return }

        runtimeStatusTask = Task { [weak self] in
            let delay = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await self?.sendRuntimeStatus(reason: .periodic)
            }
        }
    }

    private func sendRuntimeStatus(reason: RTCRuntimeStatusReason) async {
        guard runtimeStatusPolicy.isAutomaticBroadcastEnabled,
              let route = activeRoute.flatMap({ routes[$0] }) else { return }

        let delivery: ApplicationDataDelivery = route.supports(.unreliable) ? .unreliable : .reliable
        guard route.supports(delivery),
              let message = try? RTCRuntimeStatusTransport.makeMessage(
                makeRuntimeStatus(reason: reason),
                delivery: delivery
              ) else { return }

        await route.sendApplicationData(message)
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

private extension RTCCallRoute {
    func supports(_ delivery: ApplicationDataDelivery) -> Bool {
        switch delivery {
        case .reliable:
            capabilities.supportsReliableApplicationData
        case .unreliable:
            capabilities.supportsUnreliableApplicationData
        }
    }
}
