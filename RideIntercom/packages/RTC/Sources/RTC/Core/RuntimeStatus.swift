import Foundation

public enum RTCRuntimeStatusReason: String, Codable, Equatable, Sendable {
    case connectionStarted
    case routeChanged
    case mediaStarted
    case mediaStopped
    case connectionStopping
    case localControlsChanged
    case packageReportsChanged
    case periodic
}

public struct RTCRouteRuntimeStatus: Codable, Equatable, Sendable {
    public var route: RouteKind
    public var state: RouteConnectionState
    public var isAvailable: Bool
    public var availabilityReason: String?
    public var capabilities: RouteCapabilities
    public var mediaOwnership: AudioMediaOwnership
    public var isActiveRoute: Bool
    public var isMediaRoute: Bool
    public var selectedAudioCodec: RTCAudioCodecIdentifier?

    public init(
        route: RouteKind,
        state: RouteConnectionState,
        isAvailable: Bool,
        availabilityReason: String?,
        capabilities: RouteCapabilities,
        mediaOwnership: AudioMediaOwnership,
        isActiveRoute: Bool,
        isMediaRoute: Bool,
        selectedAudioCodec: RTCAudioCodecIdentifier?
    ) {
        self.route = route
        self.state = state
        self.isAvailable = isAvailable
        self.availabilityReason = availabilityReason
        self.capabilities = capabilities
        self.mediaOwnership = mediaOwnership
        self.isActiveRoute = isActiveRoute
        self.isMediaRoute = isMediaRoute
        self.selectedAudioCodec = selectedAudioCodec
    }
}

public struct RTCRuntimePackageReport: Codable, Equatable, Sendable {
    public var package: String
    public var kind: String
    public var generatedAt: TimeInterval
    public var contentType: String
    public var payload: Data

    public init(
        package: String,
        kind: String,
        generatedAt: TimeInterval = Date().timeIntervalSince1970,
        contentType: String = "application/json",
        payload: Data
    ) {
        self.package = package
        self.kind = kind
        self.generatedAt = generatedAt
        self.contentType = contentType
        self.payload = payload
    }

    public static func json<Payload: Encodable>(
        package: String,
        kind: String,
        generatedAt: TimeInterval = Date().timeIntervalSince1970,
        payload: Payload
    ) throws -> RTCRuntimePackageReport {
        RTCRuntimePackageReport(
            package: package,
            kind: kind,
            generatedAt: generatedAt,
            payload: try JSONEncoder().encode(payload)
        )
    }

    public func decodeJSON<Payload: Decodable>(_ payloadType: Payload.Type) throws -> Payload {
        try JSONDecoder().decode(payloadType, from: payload)
    }
}

public struct RTCRuntimeStatus: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var reason: RTCRuntimeStatusReason
    public var generatedAt: TimeInterval
    public var sessionID: String
    public var localPeer: PeerDescriptor
    public var expectedPeers: [PeerDescriptor]
    public var connectionState: CallConnectionState
    public var isMediaStarted: Bool
    public var localMute: Bool
    public var outputMute: Bool
    public var routeSnapshot: ActiveRouteSnapshot
    public var routes: [RTCRouteRuntimeStatus]
    public var packageReports: [RTCRuntimePackageReport]
    public var configuration: CallRouteConfiguration
    public var audioPolicy: RTCAudioPolicy

    public init(
        schemaVersion: Int = 1,
        reason: RTCRuntimeStatusReason,
        generatedAt: TimeInterval,
        sessionID: String,
        localPeer: PeerDescriptor,
        expectedPeers: [PeerDescriptor],
        connectionState: CallConnectionState,
        isMediaStarted: Bool,
        localMute: Bool,
        outputMute: Bool,
        routeSnapshot: ActiveRouteSnapshot,
        routes: [RTCRouteRuntimeStatus],
        packageReports: [RTCRuntimePackageReport] = [],
        configuration: CallRouteConfiguration,
        audioPolicy: RTCAudioPolicy
    ) {
        self.schemaVersion = schemaVersion
        self.reason = reason
        self.generatedAt = generatedAt
        self.sessionID = sessionID
        self.localPeer = localPeer
        self.expectedPeers = expectedPeers
        self.connectionState = connectionState
        self.isMediaStarted = isMediaStarted
        self.localMute = localMute
        self.outputMute = outputMute
        self.routeSnapshot = routeSnapshot
        self.routes = routes
        self.packageReports = packageReports
        self.configuration = configuration
        self.audioPolicy = audioPolicy
    }
}

public enum RTCRuntimeStatusTransport {
    public static let namespace = "rideintercom.rtc.runtimeStatus"

    public static func makeMessage(
        _ status: RTCRuntimeStatus,
        delivery: ApplicationDataDelivery = .unreliable
    ) throws -> ApplicationDataMessage {
        ApplicationDataMessage(
            namespace: namespace,
            payload: try JSONEncoder().encode(status),
            delivery: delivery
        )
    }

    public static func decode(_ message: ApplicationDataMessage) throws -> RTCRuntimeStatus? {
        guard message.namespace == namespace else {
            return nil
        }
        return try JSONDecoder().decode(RTCRuntimeStatus.self, from: message.payload)
    }
}

public struct RTCRuntimeStatusPolicy: Equatable, Sendable {
    public var isAutomaticBroadcastEnabled: Bool
    public var periodicInterval: TimeInterval?

    public init(
        isAutomaticBroadcastEnabled: Bool = true,
        periodicInterval: TimeInterval? = 5
    ) {
        self.isAutomaticBroadcastEnabled = isAutomaticBroadcastEnabled
        if let periodicInterval {
            self.periodicInterval = max(0, periodicInterval)
        } else {
            self.periodicInterval = nil
        }
    }
}
