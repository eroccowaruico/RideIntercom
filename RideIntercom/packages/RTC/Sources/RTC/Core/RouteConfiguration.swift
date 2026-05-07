import Foundation

public enum RouteKind: String, CaseIterable, Codable, Sendable {
    case multipeer
    case webRTC
}

public enum RouteSelectionMode: String, Codable, Sendable {
    case singleRoute
    case automaticFallback
    case automaticFallbackAndRestore
}

public struct CallRouteConfiguration: Codable, Equatable, Sendable {
    public var enabledRoutes: Set<RouteKind>
    public var preferredRoute: RouteKind
    public var selectionMode: RouteSelectionMode
    public var fallbackDelay: TimeInterval
    public var restoreProbeDuration: TimeInterval
    public var handoverFadeDuration: TimeInterval
    public var keepsPreferredRouteInStandby: Bool
    public var keepsFallbackRouteWarm: Bool

    public init(
        enabledRoutes: Set<RouteKind> = [.multipeer],
        preferredRoute: RouteKind = .multipeer,
        selectionMode: RouteSelectionMode = .automaticFallbackAndRestore,
        fallbackDelay: TimeInterval = 3.0,
        restoreProbeDuration: TimeInterval = 7.5,
        handoverFadeDuration: TimeInterval = 0.35,
        keepsPreferredRouteInStandby: Bool = true,
        keepsFallbackRouteWarm: Bool = false
    ) {
        self.enabledRoutes = enabledRoutes
        self.preferredRoute = preferredRoute
        self.selectionMode = selectionMode
        self.fallbackDelay = fallbackDelay
        self.restoreProbeDuration = restoreProbeDuration
        self.handoverFadeDuration = handoverFadeDuration
        self.keepsPreferredRouteInStandby = keepsPreferredRouteInStandby
        self.keepsFallbackRouteWarm = keepsFallbackRouteWarm
    }

    public func normalized() -> CallRouteConfiguration {
        guard !enabledRoutes.isEmpty, enabledRoutes.contains(preferredRoute) else {
            var copy = self
            copy.preferredRoute = enabledRoutes.sorted { $0.rawValue < $1.rawValue }.first ?? .multipeer
            return copy
        }
        return self
    }
}

public struct RouteCapabilities: Codable, Equatable, Sendable {
    public var supportsLocalDiscovery: Bool
    public var supportsOfflineOperation: Bool
    public var supportsRouteManagedMedia: Bool
    public var supportsAppManagedPacketAudio: Bool
    public var supportsReliableApplicationData: Bool
    public var supportsUnreliableApplicationData: Bool
    public var requiresSignaling: Bool
    public var supportedAudioCodecs: [RTCAudioCodecIdentifier]
    public var backendName: String?

    public init(
        supportsLocalDiscovery: Bool,
        supportsOfflineOperation: Bool,
        supportsRouteManagedMedia: Bool,
        supportsAppManagedPacketAudio: Bool,
        supportsReliableApplicationData: Bool,
        supportsUnreliableApplicationData: Bool,
        requiresSignaling: Bool,
        supportedAudioCodecs: [RTCAudioCodecIdentifier] = [],
        backendName: String? = nil
    ) {
        self.supportsLocalDiscovery = supportsLocalDiscovery
        self.supportsOfflineOperation = supportsOfflineOperation
        self.supportsRouteManagedMedia = supportsRouteManagedMedia
        self.supportsAppManagedPacketAudio = supportsAppManagedPacketAudio
        self.supportsReliableApplicationData = supportsReliableApplicationData
        self.supportsUnreliableApplicationData = supportsUnreliableApplicationData
        self.requiresSignaling = requiresSignaling
        self.supportedAudioCodecs = supportedAudioCodecs
        self.backendName = backendName
    }
}

public struct ActiveRouteSnapshot: Codable, Equatable, Sendable {
    public var activeRoute: RouteKind?
    public var mediaRoute: RouteKind?
    public var availableRoutes: Set<RouteKind>
    public var isHandoverInProgress: Bool

    public init(
        activeRoute: RouteKind?,
        mediaRoute: RouteKind?,
        availableRoutes: Set<RouteKind>,
        isHandoverInProgress: Bool
    ) {
        self.activeRoute = activeRoute
        self.mediaRoute = mediaRoute
        self.availableRoutes = availableRoutes
        self.isHandoverInProgress = isHandoverInProgress
    }
}
