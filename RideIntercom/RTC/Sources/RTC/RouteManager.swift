import Foundation

// Chooses and restores the active route while exposing a single CallSession to Core.
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
    private var isMediaActive = false

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
        isMediaActive = false

        if let preferredRoute = route(for: configuration.preferredRoute) {
            activeRouteKind = preferredRoute.kind
            preferredRoute.activate(group: group)
            scheduleFallbackIfNeeded(from: preferredRoute.kind)
            return
        }

        activateFirstAvailableRoute(group: group)
    }

    public func startMedia() {
        guard !isMediaActive else { return }
        activeRoute?.startMedia()
        isMediaActive = true
    }

    public func stopMedia() {
        guard isMediaActive else { return }
        activeRoute?.stopMedia()
        isMediaActive = false
    }

    public func disconnect() {
        fallbackTask?.cancel()
        fallbackTask = nil
        for route in routes.values {
            route.stopMedia()
            route.deactivate()
        }
        isMediaActive = false
        activeRouteKind = nil
        currentGroup = nil
    }

    public func sendAudioFrame(_ frame: OutboundAudioPacket) {
        activeRoute?.sendAudioFrame(frame)
    }

    public func sendConnectionKeepalive() {
        activeRoute?.sendConnectionKeepalive()
    }

    public func sendApplicationData(_ message: ApplicationDataMessage) {
        activeRoute?.sendApplicationData(message)
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

        if isMediaActive {
            activeRoute?.stopMedia()
        }
        activeRouteKind = fallbackRoute.kind
        fallbackRoute.activate(group: group)
        if isMediaActive {
            fallbackRoute.startMedia()
        }
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
                if isMediaActive {
                    route(for: routeKind)?.stopMedia()
                }
                activeRouteKind = fallbackRoute.kind
                fallbackRoute.activate(group: group)
                if isMediaActive {
                    fallbackRoute.startMedia()
                }
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

    public func startMedia() {}
    public func stopMedia() {}

    public func disconnect() {
        Task { @MainActor [weak self] in
            self?.onEvent?(.disconnected)
        }
    }

    public func sendAudioFrame(_ frame: OutboundAudioPacket) {}
    public func sendConnectionKeepalive() {}
    public func sendApplicationData(_ message: ApplicationDataMessage) {}

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
        supportsReliableApplicationData: true,
        supportsUnreliableApplicationData: true,
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

    public func startMedia() {}
    public func stopMedia() {}

    public func deactivate() {
        notify(.disconnected)
    }

    public func sendAudioFrame(_ frame: OutboundAudioPacket) {}
    public func sendConnectionKeepalive() {}
    public func sendApplicationData(_ message: ApplicationDataMessage) {}

    private func notify(_ event: TransportEvent) {
        Task { @MainActor [weak self] in
            self?.onEvent?(event)
        }
    }
}
