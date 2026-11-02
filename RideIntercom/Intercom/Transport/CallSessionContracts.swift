import Codec
import Foundation
import Logging
import RTC

enum ControlMessage: Equatable {
    case keepalive
    case peerMuteState(isMuted: Bool)
}

typealias ApplicationDataDelivery = RTC.ApplicationDataDelivery
typealias ApplicationDataMessage = RTC.ApplicationDataMessage

enum AppRTCTransportRoutePolicy {
    nonisolated static let supportedRoutes: Set<RTC.RouteKind> = Set(RTC.RouteKind.allCases)
}

enum LocalNetworkRejectReason: String, Equatable {
    case groupMismatch = "group mismatch"
    case handshakeInvalid = "handshake invalid"
}

enum LocalNetworkStatus: Equatable {
    case idle
    case advertisingBrowsing
    case invited
    case invitationReceived
    case connected
    case rejected(LocalNetworkRejectReason)
    case unavailable

    var label: String {
        switch self {
        case .idle:
            "MC idle"
        case .advertisingBrowsing:
            "MC advertising+browsing"
        case .invited:
            "MC invited"
        case .invitationReceived:
            "MC invitation"
        case .connected:
            "MC connected"
        case .rejected(let reason):
            "MC rejected: \(reason.rawValue)"
        case .unavailable:
            "MC unavailable"
        }
    }
}

struct LocalNetworkEvent: Equatable {
    let status: LocalNetworkStatus
    let peerID: String?
    let occurredAt: TimeInterval?

    nonisolated init(status: LocalNetworkStatus, peerID: String? = nil, occurredAt: TimeInterval? = nil) {
        self.status = status
        self.peerID = peerID
        self.occurredAt = occurredAt
    }
}


nonisolated enum AudioPacketReception: Equatable, Sendable {
    case processed(level: Float)
    case unavailable
    case decodeFailed(String)
    case failed(String)

    /// Codec decode failures get their own event; other receive failures stay pipeline-level.
    static func failure(_ error: any Error) -> AudioPacketReception {
        switch error {
        case AppAudioPipelineError.notConfigured: .unavailable
        case is CodecError, is AppAudioCodecBridge.DecodingError: .decodeFailed(String(describing: type(of: error)))
        default: .failed(String(describing: type(of: error)))
        }
    }
}

extension ApplicationDataMessage {
    /// Callers check namespace and size first, so only a known namespace reaches the log.
    func decodedPayload<T: Decodable>(_ type: T.Type, from peerID: String) -> T? {
        do { return try JSONDecoder().decode(T.self, from: payload) }
        catch {
            AppLoggers.rtc.warning("rtc.application_data.decode_failed",
                                   metadata: ApplicationDataLog.decodeFailed(namespace: namespace, peerID: peerID, error: error))
            return nil
        }
    }
}

/// Malformed application data log metadata. The payload is never recorded.
enum ApplicationDataLog {
    static func decodeFailed(namespace: String, peerID: String, error: any Error) -> Logging.Logger.Metadata {
        .event("rtc.application_data.decode_failed", [
            "namespace": "\(namespace)", "peerID": "\(peerID)", "errorType": "\(type(of: error))"
        ])
    }
}

enum TransportEvent: Equatable {
    case localNetworkStatus(LocalNetworkEvent)
    case connected(peerIDs: [String])
    case authenticated(members: [RTC.CallMemberState])
    case remotePeerMuteState(peerID: String, isMuted: Bool)
    case remotePeerMetadata(peerID: String, activeCodec: AudioCodecIdentifier?)
    case remoteRuntimeStatus(peerID: String, status: RTCRuntimeStatus)
    case receivedApplicationData(peerID: String, message: ApplicationDataMessage)
    case disconnected
    case linkFailed(willRetry: Bool)
    case receivedAudioPacket(RTC.ReceivedAudioPacket, AudioPacketReception)
    case routeMetrics(RTC.RouteMetrics)
    case networkDiagnostics(RTCNetworkDiagnostics)
    case serviceError(String)
    case serviceBlocked(String)
    case commandQueueFailed
    case routesChanged(RTC.ActiveRouteSnapshot)
}

protocol CallSession: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    var processReceivedAudio: (@Sendable (RTC.ReceivedAudioPacket) -> AudioPacketReception)? { get set }
    var audioPacketSink: @Sendable (RTC.RTCAudioPacket) -> Void { get }
    var activeRouteDebugTypeName: String { get }
    func updateInternetConfiguration(_ configuration: RTC.CloudflareRealtimeConfiguration)

    func connect(group: IntercomGroup)
    func startMedia()
    func stopMedia()
    func disconnect()
    func setAudioPolicy(_ policy: RTC.RTCAudioPolicy)
    func setEnabledRoutes(_ routes: Set<RTC.RouteKind>)
    func setLocalMute(_ muted: Bool)
    func setOutputMute(_ muted: Bool)
    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport])
    func sendAudioPacket(_ packet: RTC.RTCAudioPacket)
    func sendControl(_ message: ControlMessage)
    func sendApplicationData(_ message: ApplicationDataMessage)
}

extension CallSession {
    func updateInternetConfiguration(_ configuration: RTC.CloudflareRealtimeConfiguration) {}
}

