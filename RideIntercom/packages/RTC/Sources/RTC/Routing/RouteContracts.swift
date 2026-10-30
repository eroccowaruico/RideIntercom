import Foundation

public enum RouteEvent: Equatable, Sendable {
    var isTransient: Bool {
        switch self {
        case .metricsChanged: return true
        case .receivedApplicationData(_, let received): return received.message.delivery == .unreliable
        default: return false
        }
    }

    case stateChanged(RouteKind, RouteConnectionState)
    case availabilityChanged(RouteAvailability)
    case membersChanged(RouteKind, [CallMemberState])
    case receivedApplicationData(RouteKind, ReceivedApplicationData)
    case metricsChanged(RouteMetrics)
    case error(RouteKind, CallSessionError)
    /// Prevent automatic retries for this route until the next prepare.
    case connectionBlocked(RouteKind, String)
}

public protocol RTCCallRoute: AnyObject, Sendable {
    var kind: RouteKind { get }
    var capabilities: RouteCapabilities { get }
    var events: AsyncStream<RouteEvent> { get }

    func networkDiagnostics() async -> RTCRouteNetworkDiagnostics
    func prepare(_ request: CallStartRequest) async
    func startConnection() async
    func stopConnection() async
    /// Direct peers accepted for immediate delivery, not delivery acknowledgements.
    /// Return an empty set when the backend cannot report individual recipients.
    @discardableResult
    func sendApplicationData(_ message: ApplicationDataMessage) async -> Set<PeerID>
}

public extension RTCCallRoute {
    /// Routes without a metrics backend explicitly report unavailability.
    func networkDiagnostics() async -> RTCRouteNetworkDiagnostics { .init(route: kind) }
}
