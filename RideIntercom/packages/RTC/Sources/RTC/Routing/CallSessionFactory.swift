import Foundation

public struct WebRTCRouteFactoryConfiguration {
    public var cloudflareConfigurationProvider: @Sendable (CallStartRequest) -> CloudflareRealtimeConfiguration?
    public var signalingClientFactory: @Sendable () -> WebRTCSignalingClient
    public var engineFactory: @Sendable () -> NativeWebRTCEngine

    public init(
        cloudflareConfigurationProvider: @escaping @Sendable (CallStartRequest) -> CloudflareRealtimeConfiguration? = { _ in nil },
        signalingClientFactory: @escaping @Sendable () -> WebRTCSignalingClient = { CloudflareRealtimeSignalingClient() },
        engineFactory: @escaping @Sendable () -> NativeWebRTCEngine = { NativeWebRTCEngine() }
    ) {
        self.cloudflareConfigurationProvider = cloudflareConfigurationProvider
        self.signalingClientFactory = signalingClientFactory
        self.engineFactory = engineFactory
    }
}


public struct CallSessionFactoryConfiguration {
    public var localDisplayName: String
    public var routeConfiguration: CallRouteConfiguration
    public var audioPolicy: RTCAudioPolicy
    public var webRTC: WebRTCRouteFactoryConfiguration

    public init(
        localDisplayName: String,
        routeConfiguration: CallRouteConfiguration = CallRouteConfiguration(enabledRoutes: Set(RouteKind.allCases)),
        audioPolicy: RTCAudioPolicy = RTCAudioPolicy(),
        webRTC: WebRTCRouteFactoryConfiguration = WebRTCRouteFactoryConfiguration()
    ) {
        self.localDisplayName = localDisplayName
        self.routeConfiguration = routeConfiguration.normalized()
        self.audioPolicy = audioPolicy
        self.webRTC = webRTC
    }
}

public enum CallSessionFactory {
    public static func makeSession(_ configuration: CallSessionFactoryConfiguration) -> CallSession {
        RouteManager(
            routes: makeRoutes(configuration),
            configuration: configuration.routeConfiguration
        )
    }

    public static func makeRoutes(_ configuration: CallSessionFactoryConfiguration) -> [RTCCallRoute] {
        configuration.routeConfiguration.enabledRoutes.compactMap { route in
            switch route {
            case .multipeer:
                makeMultipeerRoute(configuration)
            case .webRTC:
                WebRTCInternetRoute(
                    cloudflareConfigurationProvider: configuration.webRTC.cloudflareConfigurationProvider,
                    signalingClient: configuration.webRTC.signalingClientFactory(),
                    engine: configuration.webRTC.engineFactory()
                )
            }
        }
    }

    private static func makeMultipeerRoute(_ configuration: CallSessionFactoryConfiguration) -> RTCCallRoute? {
        #if canImport(MultipeerConnectivity)
        MultipeerLocalRoute(
            displayName: configuration.localDisplayName,
            audioPolicy: configuration.audioPolicy
        )
        #else
        nil
        #endif
    }
}
