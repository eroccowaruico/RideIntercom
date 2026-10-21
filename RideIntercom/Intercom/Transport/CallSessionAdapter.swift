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
    case networkDiagnostics(RTCNetworkDiagnostics)
    case serviceError(String)
    case routesChanged(RTC.ActiveRouteSnapshot)
}

protocol CallSession: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    var activeRouteDebugTypeName: String { get }
    func updateInternetConfiguration(_ configuration: RTC.CloudflareRealtimeConfiguration)

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

extension CallSession {
    func updateInternetConfiguration(_ configuration: RTC.CloudflareRealtimeConfiguration) {}
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
    private var internetConfiguration: RTC.CloudflareRealtimeConfiguration?
    private let memberID: String
    private var rtcSession: RTC.CallSession
    private let ownsRTCSession: Bool
    private var eventTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var audioSendGeneration = UUID()
    private var pendingAudio: (packet: RTC.RTCAudioPacket, queuedAt: ContinuousClock.Instant)?
    private var eventGeneration = UUID()
    private var connectionRequest: RTC.CallStartRequest?
    private var mediaRequested = false
    private var audioPolicy: RTC.RTCAudioPolicy = .intercomDefault
    private var enabledRoutes: Set<RTC.RouteKind> = AppRTCTransportRoutePolicy.supportedRoutes

    init(memberID: String) {
        self.memberID = memberID
        self.ownsRTCSession = true
        self.internetConfiguration = InternetConnectionSettingsStore().load()
        self.rtcSession = Self.makeRTCSession(
            memberID: memberID,
            audioPolicy: .intercomDefault,
            enabledRoutes: AppRTCTransportRoutePolicy.supportedRoutes,
            internetConfiguration: internetConfiguration
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
        audioSendTask?.cancel()
    }

    func updateInternetConfiguration(_ configuration: RTC.CloudflareRealtimeConfiguration) {
        internetConfiguration = configuration
        if ownsRTCSession { rebuildOwnedRTCSession() }
    }

    func startStandby(group: IntercomGroup) {
        prepareConnection(group: group, start: false)
    }

    func connect(group: IntercomGroup) {
        prepareConnection(group: group, start: true)
    }

    func startMedia() {
        mediaRequested = true
        enqueue { [rtcSession] in
            await rtcSession.startMedia()
        }
    }

    func stopMedia() {
        clearPendingAudio()
        mediaRequested = false
        enqueue { [rtcSession] in
            await rtcSession.stopMedia()
        }
    }

    func disconnect() {
        connectionRequest = nil
        mediaRequested = false
        activeRouteDebugTypeName = "RTC RouteManager"
        invalidateEvents()
        enqueue { [rtcSession] in
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
        if muted { clearPendingAudio() }
        enqueue { [rtcSession] in
            await rtcSession.setLocalMute(muted)
        }
    }

    func setOutputMute(_ muted: Bool) {
        enqueue { [rtcSession] in
            await rtcSession.setOutputMute(muted)
        }
    }

    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) {
        enqueue { [rtcSession] in
            await rtcSession.updateRuntimePackageReports(reports)
        }
    }

    func sendAudioPacket(_ packet: RTC.RTCAudioPacket) {
        guard mediaRequested else { return }
        pendingAudio = (packet, .now)
        guard audioSendTask == nil else { return }
        let generation = audioSendGeneration
        let barrier = operationTask
        audioSendTask = Task { [weak self, rtcSession] in
            await barrier?.value
            while !Task.isCancelled, let self, self.audioSendGeneration == generation {
                guard let next = self.pendingAudio else { break }
                self.pendingAudio = nil
                if next.queuedAt.duration(to: .now) < .milliseconds(100) {
                    await rtcSession.sendAudioPacket(next.packet)
                }
            }
            if let self, self.audioSendGeneration == generation { self.audioSendTask = nil }
        }
    }

    private func clearPendingAudio() {
        audioSendGeneration = UUID()
        pendingAudio = nil
        audioSendTask?.cancel()
        audioSendTask = nil
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
        enqueue { [rtcSession] in
            await rtcSession.sendApplicationData(message)
        }
    }

    // App commands arrive synchronously; preserve that order across RTC actor suspensions.
    private func enqueue(_ operation: @escaping () async -> Void) {
        let previous = operationTask
        operationTask = Task {
            await previous?.value
            await operation()
        }
    }

    private func invalidateEvents() {
        clearPendingAudio()
        eventGeneration = UUID()
        eventTask?.cancel()
        eventTask = nil
    }

    private func prepareConnection(group: IntercomGroup, start: Bool) {
        let request = makeRTCRequest(from: group)
        connectionRequest = request
        invalidateEvents()
        let generation = eventGeneration
        enqueue { [weak self, rtcSession] in
            guard let self, self.eventGeneration == generation else { return }
            self.bindEvents()
            await rtcSession.prepare(request)
            if start { await rtcSession.startConnection() }
        }
    }

    private func bindEvents() {
        eventTask?.cancel()
        let generation = eventGeneration
        let events = rtcSession.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, self.eventGeneration == generation else { return }
                self.handleRTCEvent(event)
            }
        }
    }

    private func handleRTCEvent(_ event: RTC.CallSessionEvent) {
        switch event {
        case .stateChanged(let state):
            handleRTCStateChanged(state)
        case .routeChanged(let snapshot):
            // All production routes carry the same App-owned encoded audio pipeline.
            activeRouteDebugTypeName = Self.routeDebugName(snapshot.activeRoute ?? snapshot.mediaRoute)
            onEvent?(.routesChanged(snapshot))
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
        case .networkDiagnosticsChanged(let report):
            onEvent?(.networkDiagnostics(report))
        case .error(let error):
            handleRTCError(error)
        }
    }

    private func handleRTCError(_ error: RTC.CallSessionError) {
        switch error {
        case .noEnabledRoute:
            onEvent?(.linkFailed(internetAvailable: false))
        case .connectionFailed(let route, let reason):
            if route == .webRTC { onEvent?(.serviceError(reason)) }
        case .routeUnavailable,
             .signalingUnavailable,
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
        let oldSession = rtcSession
        invalidateEvents()
        enqueue { await oldSession.stopConnection() }
        rtcSession = Self.makeRTCSession(
            memberID: memberID,
            audioPolicy: audioPolicy,
            enabledRoutes: enabledRoutes,
            internetConfiguration: internetConfiguration
        )
        activeRouteDebugTypeName = "RTC RouteManager"
        if var request = connectionRequest {
            request.audioPolicy = audioPolicy
            request.configuration = makeRouteConfiguration()
            connectionRequest = request
            let shouldStartMedia = mediaRequested
            let generation = eventGeneration
            enqueue { [weak self, rtcSession, request] in
                guard let self, self.eventGeneration == generation else { return }
                self.bindEvents()
                await rtcSession.prepare(request)
                await rtcSession.startConnection()
                if shouldStartMedia { await rtcSession.startMedia() }
            }
        } else {
            bindEvents()
        }
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
        enabledRoutes: Set<RTC.RouteKind>,
        internetConfiguration: RTC.CloudflareRealtimeConfiguration?
    ) -> RTC.CallSession {
        RTC.CallSessionFactory.makeSession(
            RTC.CallSessionFactoryConfiguration(
                localDisplayName: memberID,
                routeConfiguration: makeRouteConfiguration(enabledRoutes: enabledRoutes),
                audioPolicy: audioPolicy,
                webRTC: RTC.WebRTCRouteFactoryConfiguration(
                    cloudflareConfigurationProvider: { _ in internetConfiguration },
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
