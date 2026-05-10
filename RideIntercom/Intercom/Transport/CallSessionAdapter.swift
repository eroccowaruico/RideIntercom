import Foundation
import RTC
import RTCNativeWebRTC

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


enum TransportEvent: Equatable {
    case localNetworkStatus(LocalNetworkEvent)
    case connected(peerIDs: [String])
    case authenticated(peerIDs: [String])
    case remotePeerMuteState(peerID: String, isMuted: Bool)
    case remotePeerMetadata(peerID: String, activeCodec: AudioCodecIdentifier?)
    case remoteRuntimeStatus(peerID: String, status: RTCRuntimeStatus)
    case receivedApplicationData(peerID: String, message: ApplicationDataMessage)
    case disconnected
    case linkFailed(internetAvailable: Bool)
    case receivedAudioPacket(RTC.ReceivedAudioPacket)
    case routeMetrics(RTC.RouteMetrics)
}

protocol CallSession: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    var activeRouteDebugTypeName: String { get }

    func startStandby(group: IntercomGroup)
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

private struct PeerMuteStateApplicationPayload: Codable, Equatable {
    let isMuted: Bool
}

private struct PeerMetadataApplicationPayload: Codable, Equatable {
    let activeCodec: AudioCodecIdentifier?
}

final class RideIntercomCallSessionAdapter: CallSession {
    var onEvent: ((TransportEvent) -> Void)?
    private(set) var activeRouteDebugTypeName: String = "RTC RouteManager"

    private nonisolated static let keepaliveNamespace = "rideintercom.keepalive"
    private nonisolated static let peerMuteStateNamespace = "rideintercom.peerMuteState"
    private let memberID: String
    private var rtcSession: RTC.CallSession
    private let ownsRTCSession: Bool
    private var eventTask: Task<Void, Never>?
    private var audioPolicy: RTC.RTCAudioPolicy = .intercomDefault
    private var enabledRoutes: Set<RTC.RouteKind> = AppRTCTransportRoutePolicy.supportedRoutes

    init(memberID: String) {
        self.memberID = memberID
        self.ownsRTCSession = true
        self.rtcSession = Self.makeRTCSession(
            memberID: memberID,
            audioPolicy: .intercomDefault,
            enabledRoutes: AppRTCTransportRoutePolicy.supportedRoutes
        )
        bindEvents()
    }

    init(memberID: String = "member-local", rtcSession: RTC.CallSession) {
        self.memberID = memberID
        self.ownsRTCSession = false
        self.rtcSession = rtcSession
        bindEvents()
    }

    deinit {
        eventTask?.cancel()
    }

    func startStandby(group: IntercomGroup) {
        Task { [rtcSession, request = makeRTCRequest(from: group)] in
            await rtcSession.prepare(request)
        }
    }

    func connect(group: IntercomGroup) {
        Task { [rtcSession, request = makeRTCRequest(from: group)] in
            await rtcSession.prepare(request)
            await rtcSession.startConnection()
        }
    }

    func startMedia() {
        Task { [rtcSession] in
            await rtcSession.startMedia()
        }
    }

    func stopMedia() {
        Task { [rtcSession] in
            await rtcSession.stopMedia()
        }
    }

    func disconnect() {
        Task { [rtcSession] in
            await rtcSession.stopConnection()
        }
    }

    func setAudioPolicy(_ policy: RTC.RTCAudioPolicy) {
        guard policy != audioPolicy else { return }
        audioPolicy = policy
        guard ownsRTCSession else { return }
        rebuildOwnedRTCSession()
    }

    func setEnabledRoutes(_ routes: Set<RTC.RouteKind>) {
        let requestedRoutes = routes.intersection(AppRTCTransportRoutePolicy.supportedRoutes)
        let normalizedRoutes = requestedRoutes.isEmpty ? AppRTCTransportRoutePolicy.supportedRoutes : requestedRoutes
        guard normalizedRoutes != enabledRoutes else { return }
        enabledRoutes = normalizedRoutes
        guard ownsRTCSession else { return }
        rebuildOwnedRTCSession()
    }

    func setLocalMute(_ muted: Bool) {
        Task { [rtcSession] in
            await rtcSession.setLocalMute(muted)
        }
    }

    func setOutputMute(_ muted: Bool) {
        Task { [rtcSession] in
            await rtcSession.setOutputMute(muted)
        }
    }

    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) {
        Task { [rtcSession] in
            await rtcSession.updateRuntimePackageReports(reports)
        }
    }

    func sendAudioPacket(_ packet: RTC.RTCAudioPacket) {
        Task { [rtcSession] in
            await rtcSession.sendAudioPacket(packet)
        }
    }

    func sendControl(_ message: ControlMessage) {
        switch message {
        case .keepalive:
            let payload = try? JSONEncoder().encode(PeerMetadataApplicationPayload(activeCodec: activeAudioCodec()))
            sendApplicationData(ApplicationDataMessage(
                namespace: Self.keepaliveNamespace,
                payload: payload ?? Data(),
                delivery: .unreliable
            ))
        case .peerMuteState(let isMuted):
            sendPeerMuteState(isMuted: isMuted)
        }
    }

    func sendApplicationData(_ message: ApplicationDataMessage) {
        Task { [rtcSession] in
            await rtcSession.sendApplicationData(message)
        }
    }

    private func bindEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self, rtcSession] in
            for await event in rtcSession.events {
                self?.handleRTCEvent(event)
            }
        }
    }

    private func handleRTCEvent(_ event: RTC.CallSessionEvent) {
        switch event {
        case .stateChanged(let state):
            handleRTCStateChanged(state)
        case .routeChanged(let snapshot):
            activeRouteDebugTypeName = Self.routeDebugName(snapshot.activeRoute ?? snapshot.mediaRoute)
        case .routeAvailabilityChanged:
            break
        case .membersChanged(let members):
            let peerIDs = members.map { $0.peer.id.rawValue }.filter { $0 != memberID }.sorted()
            onEvent?(.connected(peerIDs: peerIDs))
            onEvent?(.authenticated(peerIDs: peerIDs))
        case .receivedApplicationData(let received):
            onEvent?(Self.makeAppEvent(peerID: received.peerID.rawValue, applicationData: received.message))
        case .receivedAudioPacket(let received):
            onEvent?(.receivedAudioPacket(received))
        case .metricsChanged(let metrics):
            onEvent?(.routeMetrics(metrics))
        case .error(let error):
            handleRTCError(error)
        }
    }

    private func handleRTCError(_ error: RTC.CallSessionError) {
        switch error {
        case .noEnabledRoute:
            onEvent?(.linkFailed(internetAvailable: false))
        case .routeUnavailable,
             .signalingUnavailable,
             .connectionFailed,
             .unsupportedApplicationDataDelivery,
             .unsupportedAudioCodec:
            break
        }
    }

    private func handleRTCStateChanged(_ state: RTC.CallConnectionState) {
        switch state {
        case .idle:
            onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .idle, occurredAt: Date().timeIntervalSince1970)))
        case .preparing, .connecting:
            onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing, occurredAt: Date().timeIntervalSince1970)))
        case .connected, .mediaReady:
            onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .connected, occurredAt: Date().timeIntervalSince1970)))
        case .reconnecting:
            onEvent?(.linkFailed(internetAvailable: true))
        case .disconnected:
            onEvent?(.disconnected)
        case .failed:
            onEvent?(.linkFailed(internetAvailable: false))
        }
    }

    private func sendPeerMuteState(isMuted: Bool) {
        guard let payload = try? JSONEncoder().encode(PeerMuteStateApplicationPayload(isMuted: isMuted)) else { return }
        sendApplicationData(ApplicationDataMessage(
            namespace: Self.peerMuteStateNamespace,
            payload: payload,
            delivery: .reliable
        ))
    }

    private func activeAudioCodec() -> AudioCodecIdentifier {
        audioPolicy.preferredCodecs.first ?? .pcm16
    }

    private func rebuildOwnedRTCSession() {
        rtcSession = Self.makeRTCSession(
            memberID: memberID,
            audioPolicy: audioPolicy,
            enabledRoutes: enabledRoutes
        )
        activeRouteDebugTypeName = "RTC RouteManager"
        bindEvents()
    }

    private static func makeAppEvent(peerID: String, applicationData message: RTC.ApplicationDataMessage) -> TransportEvent {
        if let status = try? RTCRuntimeStatusTransport.decode(message) {
            return .remoteRuntimeStatus(peerID: peerID, status: status)
        }
        if message.namespace == peerMuteStateNamespace,
           let payload = try? JSONDecoder().decode(PeerMuteStateApplicationPayload.self, from: message.payload) {
            return .remotePeerMuteState(peerID: peerID, isMuted: payload.isMuted)
        }
        if message.namespace == keepaliveNamespace,
           let payload = try? JSONDecoder().decode(PeerMetadataApplicationPayload.self, from: message.payload) {
            return .remotePeerMetadata(peerID: peerID, activeCodec: payload.activeCodec)
        }

        return .receivedApplicationData(peerID: peerID, message: message)
    }

    private func makeRTCRequest(from group: IntercomGroup) -> RTC.CallStartRequest {
        let localMember = group.members.first(where: { $0.id == memberID })
        let localPeer = RTC.PeerDescriptor(
            id: RTC.PeerID(rawValue: memberID),
            displayName: localMember?.displayName ?? memberID
        )
        let expectedPeers = group.members
            .filter { $0.id != memberID }
            .map { RTC.PeerDescriptor(id: RTC.PeerID(rawValue: $0.id), displayName: $0.displayName) }
        return RTC.CallStartRequest(
            sessionID: group.id.uuidString,
            localPeer: localPeer,
            expectedPeers: expectedPeers,
            credential: group.accessSecret.map { RTC.RTCCredential.derived(groupID: group.id.uuidString, secret: $0) },
            configuration: makeRouteConfiguration(),
            audioPolicy: audioPolicy
        )
    }

    private func makeRouteConfiguration() -> RTC.CallRouteConfiguration {
        Self.makeRouteConfiguration(enabledRoutes: enabledRoutes)
    }

    private static func makeRTCSession(
        memberID: String,
        audioPolicy: RTC.RTCAudioPolicy,
        enabledRoutes: Set<RTC.RouteKind>
    ) -> RTC.CallSession {
        RTC.CallSessionFactory.makeSession(
            RTC.CallSessionFactoryConfiguration(
                localDisplayName: memberID,
                routeConfiguration: makeRouteConfiguration(enabledRoutes: enabledRoutes),
                audioPolicy: audioPolicy,
                webRTC: RTC.WebRTCRouteFactoryConfiguration(
                    engineFactory: { WebRTCNativeEngine() }
                )
            )
        )
    }

    private static func makeRouteConfiguration(enabledRoutes: Set<RTC.RouteKind>) -> RTC.CallRouteConfiguration {
        let preferredRoute: RTC.RouteKind
        if enabledRoutes.contains(.multipeer) {
            preferredRoute = .multipeer
        } else if enabledRoutes.contains(.webRTC) {
            preferredRoute = .webRTC
        } else {
            preferredRoute = .multipeer
        }

        return RTC.CallRouteConfiguration(
            enabledRoutes: enabledRoutes,
            preferredRoute: preferredRoute
        )
    }

    private static func routeDebugName(_ route: RTC.RouteKind?) -> String {
        switch route {
        case .multipeer:
            "MultipeerLocalRoute"
        case .webRTC:
            "WebRTCInternetRoute"
        case nil:
            "RTC RouteManager"
        }
    }
}
