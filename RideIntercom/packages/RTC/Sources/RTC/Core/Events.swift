import Foundation

public enum CallConnectionState: String, Codable, Equatable, Sendable {
    case idle
    case preparing
    case connecting
    case connected
    case mediaReady
    case reconnecting
    case disconnected
    case failed
}

public enum RouteConnectionState: String, Codable, Equatable, Sendable {
    case idle
    case standby
    case connecting
    case connected
    case authenticated
    case mediaReady
    case disconnected
    case failed
}

public struct CallMemberState: Codable, Equatable, Sendable {
    public var peer: PeerDescriptor
    public var route: RouteKind?
    public var isConnected: Bool
    public var isMuted: Bool

    public init(peer: PeerDescriptor, route: RouteKind?, isConnected: Bool, isMuted: Bool = false) {
        self.peer = peer
        self.route = route
        self.isConnected = isConnected
        self.isMuted = isMuted
    }
}

public enum CallSessionError: Error, Equatable, Sendable {
    case noEnabledRoute
    case routeUnavailable(RouteKind)
    case signalingUnavailable(RouteKind)
    case connectionFailed(RouteKind, String)
    case unsupportedApplicationDataDelivery(RouteKind, ApplicationDataDelivery)
    case unsupportedAudioCodec(RouteKind, requested: [RTCAudioCodecIdentifier], supported: [RTCAudioCodecIdentifier])
}

public struct RouteAvailability: Codable, Equatable, Sendable {
    public var route: RouteKind
    public var isAvailable: Bool
    public var reason: String?

    public init(route: RouteKind, isAvailable: Bool, reason: String? = nil) {
        self.route = route
        self.isAvailable = isAvailable
        self.reason = reason
    }
}

public struct RouteMetrics: Codable, Equatable, Sendable {
    public var route: RouteKind
    public var rtt: TimeInterval?
    public var jitter: TimeInterval?
    public var packetLoss: Double?
    public var activePeerCount: Int
    public var audioPlayoutDelay: TimeInterval?
    public var receivedAudioFrameCount: Int
    public var droppedAudioFrameCount: Int
    public var queuedAudioFrameCount: Int

    public init(
        route: RouteKind,
        rtt: TimeInterval? = nil,
        jitter: TimeInterval? = nil,
        packetLoss: Double? = nil,
        activePeerCount: Int = 0,
        audioPlayoutDelay: TimeInterval? = nil,
        receivedAudioFrameCount: Int = 0,
        droppedAudioFrameCount: Int = 0,
        queuedAudioFrameCount: Int = 0
    ) {
        self.route = route
        self.rtt = rtt
        self.jitter = jitter
        self.packetLoss = packetLoss
        self.activePeerCount = activePeerCount
        self.audioPlayoutDelay = audioPlayoutDelay
        self.receivedAudioFrameCount = receivedAudioFrameCount
        self.droppedAudioFrameCount = droppedAudioFrameCount
        self.queuedAudioFrameCount = queuedAudioFrameCount
    }
}

public enum CallSessionEvent: Equatable, Sendable {
    case stateChanged(CallConnectionState)
    case routeChanged(ActiveRouteSnapshot)
    case routeAvailabilityChanged([RouteAvailability])
    case membersChanged([CallMemberState])
    case receivedApplicationData(ReceivedApplicationData)
    case receivedAudioPacket(ReceivedAudioPacket)
    case metricsChanged(RouteMetrics)
    case error(CallSessionError)
}
