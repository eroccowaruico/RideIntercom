import Foundation

/// Counts mailbox deliveries, not network packet loss. Each subscriber can drop its own copy.
public struct RTCEventDropReport: Codable, Equatable, Sendable {
    public var overflow: Int = 0
    public var expired: Int = 0
    public init() {}
}

public struct RTCNetworkStatistics: Codable, Equatable, Sendable {
    public var roundTripTime: TimeInterval?
    public var sentMediaDatagrams: UInt64? = nil
    public var receivedMediaDatagrams: UInt64? = nil
    public var bufferedBytes: UInt64?
    /// DataChannel/SCTP does not expose an RTP packet-loss fraction. Never substitute zero.
    public var packetLoss: Double? = nil
    public var unavailableReason: String
    public init(roundTripTime: TimeInterval? = nil, bufferedBytes: UInt64? = nil,
                unavailableReason: String = "Network statistics are unavailable") {
        self.roundTripTime = roundTripTime; self.bufferedBytes = bufferedBytes
        self.unavailableReason = unavailableReason
    }
}

public struct RTCRouteNetworkDiagnostics: Codable, Equatable, Sendable {
    public var route: RouteKind
    public var statistics: RTCNetworkStatistics
    public var eventDrops: [String: RTCEventDropReport]
    public init(route: RouteKind, statistics: RTCNetworkStatistics = .init(), eventDrops: [String: RTCEventDropReport] = [:]) {
        self.route = route; self.statistics = statistics; self.eventDrops = eventDrops
    }
}

/// Last accepted authenticated path, not a prediction of end-to-end availability.
public struct RTCObservedPeerPath: Codable, Equatable, Sendable {
    public var peerID: PeerID
    public var route: RouteKind
    public var path: [PeerID]
    public var observedAt: TimeInterval
    public init(peerID: PeerID, route: RouteKind, path: [PeerID], observedAt: TimeInterval) {
        self.peerID = peerID; self.route = route; self.path = path; self.observedAt = observedAt
    }
}

public struct RTCNetworkDiagnostics: Codable, Equatable, Sendable {
    public var generatedAt: TimeInterval
    public var eventDrops: RTCEventDropReport
    public var routes: [RTCRouteNetworkDiagnostics]
    public var peers: [RTCObservedPeerPath]
    public init(generatedAt: TimeInterval = Date().timeIntervalSince1970, eventDrops: RTCEventDropReport = .init(),
                routes: [RTCRouteNetworkDiagnostics] = [], peers: [RTCObservedPeerPath] = []) {
        self.generatedAt = generatedAt; self.eventDrops = eventDrops; self.routes = routes; self.peers = peers
    }
}
