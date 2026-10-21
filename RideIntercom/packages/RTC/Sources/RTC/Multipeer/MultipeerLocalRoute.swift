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
            supportedAudioCodecs: audioPolicy.preferredCodecs,
            backendName: "MultipeerConnectivity"
        )
    }
    nonisolated public var events: AsyncStream<RouteEvent> { eventSource.stream }

    private let eventSource = EventSource<RouteEvent>(isTransient: { $0.isTransient }, overflowEvent: .stateChanged(.multipeer, .failed))
    private let audioPolicy: RTCAudioPolicy
    private var generation = UUID()
    private var transportEventsTask: Task<Void, Never>?
    private var transportSource: EventSource<MultipeerConnectionEvent>?
    private var transport: MultipeerConnectionTransport?

    public init(
        audioPolicy: RTCAudioPolicy = RTCAudioPolicy()
    ) {
        self.audioPolicy = audioPolicy
    }

    deinit {
        transportEventsTask?.cancel()
        transport?.stop()
    }

    public func networkDiagnostics() async -> RTCRouteNetworkDiagnostics {
        .init(route: kind, statistics: .init(unavailableReason: "MultipeerConnectivity does not expose RTT, loss or buffered bytes"),
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

    public func sendApplicationData(_ message: ApplicationDataMessage) async {
        guard let payload = try? MultipeerPayloadBuilder.makeApplicationDataPayload(message) else { return }
        transport?.send(payload)
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
    var onEvent: ((MultipeerConnectionEvent) -> Void)?

    private let request: CallStartRequest
    private let credential: RTCCredential?
    private let localPeerID: MCPeerID
    private var session: MCSession
    // Bonjour's browser/monitor lifecycle belongs to the main run loop. Starting
    // and destroying it on another queue races its pending cancellation callback.
    private let queue = DispatchQueue.main
    private var isStopped = false
    private var connectedPeerIDs: Set<PeerID> = []
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var authenticatedPeers: Set<PeerID> = []
    private var pendingInvites: Set<String> = []

    init(request: CallStartRequest) {
        self.request = request
        self.credential = request.credential
        self.localPeerID = MCPeerID(displayName: request.localPeer.id.rawValue)
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    private func onQueue<T>(_ operation: () -> T) -> T {
        if Thread.isMainThread { return operation() }
        return queue.sync(execute: operation)
    }

    func start() {
        onQueue { [self] in
            stopDiscovery()
            session.delegate = nil
            session.disconnect()
            session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self
            isStopped = false
            connectedPeerIDs.removeAll()
            authenticatedPeers.removeAll()
            onEvent?(.state(.connecting))

            let advertiser = MCNearbyServiceAdvertiser(
                peer: localPeerID,
                discoveryInfo: credential.map { [LocalDiscoveryInfo.groupHashKey: $0.groupHash] },
                serviceType: LocalDiscoveryInfo.serviceType
            )
            advertiser.delegate = self
            self.advertiser = advertiser
            advertiser.startAdvertisingPeer()

            let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: LocalDiscoveryInfo.serviceType)
            browser.delegate = self
            self.browser = browser
            browser.startBrowsingForPeers()

        }
    }

    func stop() {
        onQueue { [self] in
            isStopped = true
            connectedPeerIDs.removeAll()
            stopDiscovery()
            session.delegate = nil
            session.disconnect()
            authenticatedPeers.removeAll()
            onEvent?(.state(.disconnected))

        }
    }

    func send(_ payload: TransportPayload) {
        onQueue { [self] in
            guard !isStopped else { return }
            let peers = session.connectedPeers.filter { authenticatedPeers.contains(PeerID(rawValue: $0.displayName)) }
            guard !peers.isEmpty else { return }
            do {
                try session.send(payload.data, toPeers: peers, with: payload.mcSendMode)
            } catch {
                onEvent?(.failed("Multipeer payload send failed"))
            }

        }
    }

    func accept(_ handshake: RouteHandshakeMessage, from peerID: PeerID) -> Bool {
        return onQueue { [self] in
            guard !isStopped, connectedPeerIDs.contains(peerID) else { return false }
            guard let credential else {
                authenticatedPeers.insert(peerID)
                onEvent?(.members(Array(authenticatedPeers)))
                return true
            }
            guard handshake.verify(credential: credential) else { return false }
            authenticatedPeers.insert(peerID)
            onEvent?(.members(Array(authenticatedPeers)))
            return true

        }
    }

    private func stopDiscovery() {
        advertiser?.delegate = nil
        browser?.delegate = nil
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        pendingInvites.removeAll()
    }

    private func sendHandshake(to peerID: MCPeerID) {
        guard let credential else {
            authenticatedPeers.insert(PeerID(rawValue: peerID.displayName))
            onEvent?(.members(Array(authenticatedPeers)))
            onEvent?(.state(.authenticated))
            return
        }
        do {
            let handshake = RouteHandshakeMessage.make(credential: credential, senderID: request.localPeer.id)
            let payload = try MultipeerPayloadBuilder.makeControlPayload(.handshake(handshake))
            try session.send(payload.data, toPeers: [peerID], with: payload.mcSendMode)
        } catch {
            onEvent?(.failed("Multipeer handshake send failed"))
        }
    }
}

extension MultipeerConnectionTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        queue.async { [self] in
            guard !isStopped, self.browser === browser else { return }
            guard peerID != localPeerID else { return }
            if let credential, info?[LocalDiscoveryInfo.groupHashKey] != credential.groupHash { return }
            guard !pendingInvites.contains(peerID.displayName), !session.connectedPeers.contains(peerID) else { return }
            pendingInvites.insert(peerID.displayName)
            browser.invitePeer(
                peerID,
                to: session,
                withContext: credential.flatMap { LocalInvitationContext(groupHash: $0.groupHash).encoded },
                timeout: 10
            )

        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { [self] in
            guard !isStopped, self.browser === browser else { return }
            pendingInvites.remove(peerID.displayName)

        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        queue.async { [self] in
            guard !isStopped, self.browser === browser else { return }
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
            guard !isStopped, self.advertiser === advertiser else { return nil }
            if let credential, LocalInvitationContext.decode(context)?.groupHash != credential.groupHash { return nil }
            return session
        }
        invitationHandler(acceptedSession != nil, acceptedSession)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        queue.async { [self] in
            guard !isStopped, self.advertiser === advertiser else { return }
            onEvent?(.failed(error.localizedDescription))

        }
    }
}

extension MultipeerConnectionTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async { [self] in
            guard !isStopped, self.session === session else { return }
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
                authenticatedPeers.remove(PeerID(rawValue: peerID.displayName))
                onEvent?(.members(Array(authenticatedPeers)))
                onEvent?(.state(connectedPeerIDs.isEmpty ? .disconnected : (authenticatedPeers.isEmpty ? .connected : .authenticated)))
            @unknown default:
                break
            }

        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= 65536 else { return }
        queue.async { [self] in
            guard !isStopped, self.session === session else { return }
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
