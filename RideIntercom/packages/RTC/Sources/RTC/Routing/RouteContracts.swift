import Foundation

public enum RouteEvent: Equatable, Sendable {
    case stateChanged(RouteKind, RouteConnectionState)
    case availabilityChanged(RouteAvailability)
    case membersChanged(RouteKind, [CallMemberState])
    case receivedApplicationData(RouteKind, ReceivedApplicationData)
    case receivedAudioPacket(RouteKind, ReceivedAudioPacket)
    case metricsChanged(RouteMetrics)
    case error(RouteKind, CallSessionError)
}

public protocol RTCCallRoute: AnyObject, Sendable {
    var kind: RouteKind { get }
    var capabilities: RouteCapabilities { get }
    var mediaOwnership: AudioMediaOwnership { get }
    var events: AsyncStream<RouteEvent> { get }

    func prepare(_ request: CallStartRequest) async
    func startConnection() async
    func stopConnection() async
    func startMedia() async
    func stopMedia() async
    func sendAudioPacket(_ packet: RTCAudioPacket) async
    func sendApplicationData(_ message: ApplicationDataMessage) async
    func setLocalMute(_ muted: Bool) async
    func setOutputMute(_ muted: Bool) async
}

public struct AnyRouteFactory: Sendable {
    public var kind: RouteKind
    private let makeRoute: @Sendable () -> RTCCallRoute

    public init(kind: RouteKind, makeRoute: @escaping @Sendable () -> RTCCallRoute) {
        self.kind = kind
        self.makeRoute = makeRoute
    }

    public func make() -> RTCCallRoute {
        makeRoute()
    }
}
