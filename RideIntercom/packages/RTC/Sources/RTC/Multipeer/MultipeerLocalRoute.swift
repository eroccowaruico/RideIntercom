#if canImport(MultipeerConnectivity)
import Foundation
@preconcurrency import MultipeerConnectivity

public actor MultipeerLocalRoute: RTCCallRoute {
    public let kind: RouteKind = .multipeer
    nonisolated public var capabilities: RouteCapabilities {
        RouteCapabilities(
            supportsLocalDiscovery: true,
            supportsOfflineOperation: true,
            supportsReliableApplicationData: true,
            supportsUnreliableApplicationData: true,
            requiresSignaling: false,
            supportedAudioCodecs: [.pcm16, .opus, .mpeg4AACELD, .mpeg4AACELDv2],
            backendName: "Local UDP / Multipeer control"
        )
    }
    nonisolated public var events: AsyncStream<RouteEvent> { eventSource.stream }

    private let eventSource = EventSource<RouteEvent>(isTransient: { $0.isTransient }, overflowEvent: .stateChanged(.multipeer, .failed))
    private var generation = UUID()
    private var transportEventsTask: Task<Void, Never>?
    private var transportSource: EventSource<MultipeerConnectionEvent>?
    private var transport: MultipeerConnectionTransport?

    public init() {}

    deinit {
        transportEventsTask?.cancel()
        transport?.stop()
    }

    public func networkDiagnostics() async -> RTCRouteNetworkDiagnostics {
        .init(route: kind, statistics: transport?.mediaStatistics ?? .init(),
              eventDrops: ["route": eventSource.report, "transport": transportSource?.report ?? .init()])
    }
    public func prepare(_ request: CallStartRequest) async {
        eventSource.resetDiagnostics()
        generation = UUID()
        transportEventsTask?.cancel()
        transport?.stop()
        transport = nil
        guard (1...63).contains(request.localPeer.id.rawValue.utf8.count) else {
            eventSource.yield(.error(kind, .connectionFailed(kind, "Invalid local peer identifier")))
            eventSource.yield(.stateChanged(kind, .failed))
            return
        }
        let transport = MultipeerConnectionTransport(request: request)
        let source = EventSource<MultipeerConnectionEvent>(isTransient: { $0.isTransient }, overflowEvent: .failed("Control event queue overflow"))
        transportSource = source
        transport.onEvent = { source.yield($0) }
        let generation = generation
        let events = source.stream
        transportEventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleTransportEvent(event, generation: generation)
            }
        }
        self.transport = transport
        eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: true)))
        eventSource.yield(.stateChanged(kind, .standby))
    }

    public func startConnection() async {
        guard let transport else { return }
        let token = generation
        _ = await MultipeerStreamRuntime.prepare()
        guard generation == token, !Task.isCancelled else { return }
        transport.start()
        eventSource.yield(.stateChanged(kind, .connecting))
    }

    public func stopConnection() async {
        generation = UUID()
        transportEventsTask?.cancel()
        transportEventsTask = nil
        transport?.stop()
        transport = nil
        eventSource.yield(.stateChanged(kind, .disconnected))
    }

    @discardableResult
    public func sendApplicationData(_ message: ApplicationDataMessage) async -> Set<PeerID> {
        guard let payload = try? MultipeerPayloadBuilder.makeApplicationDataPayload(message) else { return [] }
        return transport?.send(payload) ?? []
    }


    private func handleTransportEvent(_ event: MultipeerConnectionEvent, generation: UUID) {
        guard self.generation == generation else { return }
        switch event {
        case .state(let state):
            eventSource.yield(.stateChanged(kind, state))
        case .members(let peers):
            let members = peers.map {
                CallMemberState(peer: PeerDescriptor(id: $0, displayName: $0.rawValue), route: kind, isConnected: true)
            }
            eventSource.yield(.membersChanged(kind, members))
            eventSource.yield(.metricsChanged(RouteMetrics(route: kind, activePeerCount: peers.count)))
        case .message(let message, let peerID):
            handleWireMessage(message, from: peerID)
        case .failed(let message):
            eventSource.yield(.error(kind, .connectionFailed(kind, message)))
            eventSource.yield(.stateChanged(kind, .failed))
        }
    }

    private func handleWireMessage(_ message: MultipeerWireMessage, from peerID: PeerID) {
        switch message {
        case .control(let payload):
            handleControlPayload(payload, from: peerID)
        case .applicationData(let message):
            eventSource.yield(.receivedApplicationData(kind, ReceivedApplicationData(peerID: peerID, message: message)))
        }
    }

    private func handleControlPayload(_ payload: RouteControlPayload, from peerID: PeerID) {
        switch payload {
        case .handshake(let handshake):
            guard transport?.accept(handshake, from: peerID) == true else {
                eventSource.yield(.error(kind, .connectionFailed(kind, "Multipeer handshake rejected")))
                return
            }
            eventSource.yield(.stateChanged(kind, .authenticated))
        }
    }
}

enum MultipeerConnectionEvent: Sendable {
    var isTransient: Bool {
        switch self {
        case .message(.applicationData(let message), _): return message.delivery == .unreliable
        default: return false
        }
    }

    case state(RouteConnectionState)
    case members([PeerID])
    case message(MultipeerWireMessage, PeerID)
    case failed(String)
}

final class MultipeerConnectionTransport: NSObject, @unchecked Sendable {
    private let mediaLock = NSLock()
    private var eventHandler: (@Sendable (MultipeerConnectionEvent) -> Void)?
    var onEvent: (@Sendable (MultipeerConnectionEvent) -> Void)? {
        get { mediaLock.withLock { eventHandler } }
        set { mediaLock.withLock { eventHandler = newValue } }
    }

    private let request: CallStartRequest
    private let credential: RTCCredential?
    private let native: MultipeerNativeResources
    private var datagrams: LocalDatagramTransport?
    private var isStopped = false
    private var connectedPeerIDs: Set<PeerID> = []
    private var authenticatedPeers: Set<PeerID> = []
    private var storedMediaPeers: Set<PeerID> = []
    private var mediaStopped = false
    // Only control mutates membership. UDP takes a small immutable snapshot;
    // it never enters the UI/Bonjour actor or waits behind reliable sends.
    private var mediaPeers: Set<PeerID> {
        get { mediaLock.withLock { storedMediaPeers } }
        set { mediaLock.withLock { storedMediaPeers = newValue } }
    }
    private var pendingInvites: Set<String> = []

    init(request: CallStartRequest) {
        self.request = request
        self.credential = request.credential
        if Thread.isMainThread {
            self.native = MainActor.assumeIsolated { MultipeerNativeResources(peerName: request.localPeer.id.rawValue) }
        } else {
            self.native = DispatchQueue.main.sync { MultipeerNativeResources(peerName: request.localPeer.id.rawValue) }
        }
        super.init()
        if let credential {
            datagrams = LocalDatagramTransport(peerID: request.localPeer.id, groupHash: credential.groupHash) { [weak self] peer, data in
                self?.receiveDatagram(data, from: peer)
            }
        }
        datagrams?.onFailure = { [weak self] reason in
            self?.enqueue { [weak self] in
                guard let self, !self.isStopped else { return }
                self.onEvent?(.failed(reason))
            }
        }
        onQueue { native.session.delegate = self }
    }

    private func onQueue<T: Sendable>(_ operation: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(operation) }
        return DispatchQueue.main.sync(execute: operation)
    }

    private func enqueue(_ operation: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async(execute: operation)
    }

    var mediaStatistics: RTCNetworkStatistics { datagrams?.statistics ?? .init() }

    func receiveDatagram(_ data: Data, from peer: PeerID) {
        let handler = mediaLock.withLock {
            !mediaStopped && storedMediaPeers.contains(peer) ? eventHandler : nil
        }
        // Only the encrypted group envelope travels over UDP. GroupRelay
        // authenticates its claimed origin, path, epoch and sequence.
        handler?(.message(.applicationData(.init(namespace: GroupRelay.namespace,
            payload: data, delivery: .unreliable)), peer))
    }

    func start() {
        onQueue { [self] in
            stopDiscovery()
            native.session.delegate = nil
            native.session.disconnect()
            native.session = MCSession(peer: native.localPeerID, securityIdentity: nil, encryptionPreference: .required)
            native.session.delegate = self
            isStopped = false
            mediaLock.withLock { mediaStopped = false }
            connectedPeerIDs.removeAll()
            authenticatedPeers.removeAll()
            mediaPeers.removeAll()
            onEvent?(.state(.connecting))
            do { try datagrams?.start() }
            catch { onEvent?(.failed("Local UDP listener could not start")); return }

            let advertiser = MCNearbyServiceAdvertiser(
                peer: native.localPeerID,
                discoveryInfo: credential.map { [LocalDiscoveryInfo.groupHashKey: $0.groupHash] },
                serviceType: LocalDiscoveryInfo.serviceType
            )
            advertiser.delegate = self
            native.advertiser = advertiser
            advertiser.startAdvertisingPeer()

            let browser = MCNearbyServiceBrowser(peer: native.localPeerID, serviceType: LocalDiscoveryInfo.serviceType)
            browser.delegate = self
            native.browser = browser
            browser.startBrowsingForPeers()

        }
    }

    func stop() {
        mediaLock.withLock { mediaStopped = true; storedMediaPeers.removeAll() }
        onQueue { [self] in
            isStopped = true
            datagrams?.stop()
            connectedPeerIDs.removeAll()
            stopDiscovery()
            native.session.delegate = nil
            native.session.disconnect()
            authenticatedPeers.removeAll()
            mediaPeers.removeAll()
            onEvent?(.state(.disconnected))

        }
    }

    @discardableResult
    func send(_ payload: TransportPayload) -> Set<PeerID> {
        if let audio = payload.groupAudio {
            let peers = mediaLock.withLock { mediaStopped ? [] : Array(storedMediaPeers) }
            guard !peers.isEmpty else { return [] }
            return datagrams?.send(audio, to: peers) ?? []
        }
        onQueue { [self] in
            guard !isStopped else { return }
            let peers = native.session.connectedPeers.filter { authenticatedPeers.contains(PeerID(rawValue: $0.displayName)) }
            guard !peers.isEmpty else { return }
            do {
                try native.session.send(payload.data, toPeers: peers, with: payload.mcSendMode)
            } catch {
                onEvent?(.failed("Multipeer payload send failed"))
            }
        }
        return []
    }

    func accept(_ handshake: RouteHandshakeMessage, from peerID: PeerID) -> Bool {
        return onQueue { [self] in
            guard !isStopped, connectedPeerIDs.contains(peerID) else { return false }
            guard let credential else {
                authenticatedPeers.insert(peerID)
                onEvent?(.members(Array(authenticatedPeers)))
                return true
            }
            guard handshake.senderID == peerID, handshake.verify(credential: credential) else { return false }
            if !mediaPeers.contains(peerID), mediaPeers.count >= 7 {
                guard let departed = mediaPeers.subtracting(connectedPeerIDs).first else { return false }
                mediaPeers.remove(departed)
                datagrams?.remove(departed)
            }
            let newlyAuthenticated = authenticatedPeers.insert(peerID).inserted
            mediaPeers.insert(peerID)
            // Repeated handshakes on the same control session are idempotent.
            // A reconnection must resolve again even if its old UDP flow is ready.
            if newlyAuthenticated { datagrams?.connect(to: peerID, nonce: handshake.nonce) }
            onEvent?(.members(Array(mediaPeers)))
            return true

        }
    }

    @MainActor private func stopDiscovery() {
        native.advertiser?.delegate = nil
        native.browser?.delegate = nil
        native.advertiser?.stopAdvertisingPeer()
        native.browser?.stopBrowsingForPeers()
        native.advertiser = nil
        native.browser = nil
        pendingInvites.removeAll()
    }

    @MainActor private func sendHandshake(to peerID: MCPeerID) {
        guard let credential else {
            authenticatedPeers.insert(PeerID(rawValue: peerID.displayName))
            onEvent?(.members(Array(authenticatedPeers)))
            onEvent?(.state(.authenticated))
            return
        }
        do {
            // This nonce is authenticated by the existing handshake MAC. It also
            // names this listener generation, not an unauthenticated UDP address.
            let handshake = RouteHandshakeMessage.make(credential: credential, senderID: request.localPeer.id,
                nonce: datagrams?.serviceNonce ?? UUID().uuidString)
            let payload = try MultipeerPayloadBuilder.makeControlPayload(.handshake(handshake))
            try native.session.send(payload.data, toPeers: [peerID], with: payload.mcSendMode)
        } catch {
            onEvent?(.failed("Multipeer handshake send failed"))
        }
    }
}

extension MultipeerConnectionTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        enqueue { [self] in
            guard !isStopped, native.browser === browser else { return }
            guard peerID != native.localPeerID else { return }
            if let credential, info?[LocalDiscoveryInfo.groupHashKey] != credential.groupHash { return }
            // Both endpoints advertise and browse. Elect one initiator so two
            // simultaneous invitations cannot tear down each other's session.
            guard native.localPeerID.displayName < peerID.displayName else { return }
            guard !pendingInvites.contains(peerID.displayName), !native.session.connectedPeers.contains(peerID) else { return }
            pendingInvites.insert(peerID.displayName)
            browser.invitePeer(
                peerID,
                to: native.session,
                withContext: credential.flatMap { LocalInvitationContext(groupHash: $0.groupHash).encoded },
                timeout: 10
            )

        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        enqueue { [self] in
            guard !isStopped, native.browser === browser else { return }
            pendingInvites.remove(peerID.displayName)

        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        enqueue { [self] in
            guard !isStopped, native.browser === browser else { return }
            onEvent?(.failed(error.localizedDescription))

        }
    }
}

extension MultipeerConnectionTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let acceptedSession: MCSession? = onQueue {
            guard !isStopped, native.advertiser === advertiser else { return nil }
            if let credential, LocalInvitationContext.decode(context)?.groupHash != credential.groupHash { return nil }
            return native.session
        }
        invitationHandler(acceptedSession != nil, acceptedSession)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        enqueue { [self] in
            guard !isStopped, native.advertiser === advertiser else { return }
            onEvent?(.failed(error.localizedDescription))

        }
    }
}

extension MultipeerConnectionTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        enqueue { [self] in
            guard !isStopped, native.session === session else { return }
            switch state {
            case .connected:
                connectedPeerIDs.insert(PeerID(rawValue: peerID.displayName))
                pendingInvites.remove(peerID.displayName)
                onEvent?(.state(.connected))
                sendHandshake(to: peerID)
            case .connecting:
                onEvent?(.state(.connecting))
            case .notConnected:
                connectedPeerIDs.remove(PeerID(rawValue: peerID.displayName))
                pendingInvites.remove(peerID.displayName)
                // A control stream interruption does not tear down UDP media.
                // GroupRelay expires absent peers and rejects expired/left epochs.
                authenticatedPeers.remove(PeerID(rawValue: peerID.displayName))
                let reachable = authenticatedPeers.union(mediaPeers)
                onEvent?(.members(Array(reachable)))
                onEvent?(.state(!reachable.isEmpty ? .authenticated : (connectedPeerIDs.isEmpty ? .disconnected : .connected)))
            @unknown default:
                break
            }

        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= 65536 else { return }
        enqueue { [self] in
            guard !isStopped, native.session === session else { return }
            do {
                let message = try MultipeerPayloadBuilder.decode(data)
                if case .control(.handshake) = message {
                    guard connectedPeerIDs.contains(PeerID(rawValue: peerID.displayName)) else { return }
                } else {
                    guard authenticatedPeers.contains(PeerID(rawValue: peerID.displayName)) else { return }
                }
                onEvent?(.message(message, PeerID(rawValue: peerID.displayName)))
            } catch {
                // Invalid remote payloads are dropped without logging identifiers or data.
            }

        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

/// Multipeer owns Bonjour run-loop state even inside MCSession. Keep creation,
/// mutation AND final release on the main actor; the route itself is an actor
/// whose last reference can otherwise disappear on a cooperative worker thread.
@MainActor
private final class MultipeerNativeResources {
    let localPeerID: MCPeerID
    var session: MCSession
    var advertiser: MCNearbyServiceAdvertiser?
    var browser: MCNearbyServiceBrowser?

    init(peerName: String) {
        localPeerID = MCPeerID(displayName: peerName)
        session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
    }

    isolated deinit {
        advertiser?.delegate = nil
        browser?.delegate = nil
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.delegate = nil
        session.disconnect()
    }
}

enum LocalDiscoveryInfo {
    static let serviceType = "ride-intercom"
    static let groupHashKey = "groupHash"
}

private struct LocalInvitationContext: Codable, Equatable {
    var groupHash: String
    var encoded: Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data?) -> LocalInvitationContext? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

private extension TransportPayload {
    var mcSendMode: MCSessionSendDataMode {
        switch mode {
        case .reliable:
            .reliable
        case .unreliable:
            .unreliable
        }
    }
}
#endif
