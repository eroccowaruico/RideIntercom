#if canImport(MultipeerConnectivity)
import Foundation
import MultipeerConnectivity
import OSLog

// Local/offline route backed by MultipeerConnectivity discovery, control, and packet audio.
public final class MultipeerLocalRoute: CallRoute {
    public let kind: RouteKind = .multipeer
    public let capabilities = RouteCapabilities(
        supportsLocalDiscovery: true,
        supportsOfflineOperation: true,
        supportsManagedMediaStream: false,
        supportsAppManagedPacketMedia: true,
        supportsReliableControl: true,
        supportsUnreliableControl: true,
        supportsReliableApplicationData: true,
        supportsUnreliableApplicationData: true,
        requiresSignaling: false
    )
    public var onEvent: (@MainActor (TransportEvent) -> Void)? {
        get { transport.onEvent }
        set { transport.onEvent = newValue }
    }
    public var debugTypeName: String { String(describing: type(of: transport)) }
    public let mediaMode: RouteMediaMode = .appManagedPacketAudio

    private let transport: MultipeerLocalTransport

    public init(displayName: String) {
        self.transport = MultipeerLocalTransport(displayName: displayName)
    }

    public func startStandby(group: CallGroup) {
        transport.connect(group: group)
    }

    public func activate(group: CallGroup) {
        transport.connect(group: group)
    }

    public func startMedia() {
        transport.startMedia()
    }

    public func stopMedia() {
        transport.stopMedia()
    }

    public func deactivate() {
        transport.disconnect()
    }

    public func sendAudioFrame(_ frame: OutboundAudioPacket) {
        transport.sendAudioFrame(frame)
    }

    public func sendConnectionKeepalive() {
        transport.sendConnectionKeepalive()
    }

    public func sendApplicationData(_ message: ApplicationDataMessage) {
        transport.sendApplicationData(message)
    }
}

final class MultipeerLocalTransport: NSObject {
    let route: TransportRoute = .local
    var onEvent: (@MainActor (TransportEvent) -> Void)?

    private let localPeerID: MCPeerID
    private let session: MCSession
    private let logger = Logger(subsystem: "com.yowamushi-inc.RideIntercom", category: "rtc-multipeer")
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var credential: GroupAccessCredential?
    private var handshakeRegistry: HandshakeRegistry?
    private var sequencer: AudioPacketSequencer?
    private var receivedPacketFilter: ReceivedAudioPacketFilter?
    private(set) var receivedPackets: [ReceivedAudioPacket] = []
    private var pendingOutgoingInvitationPeerIDs: Set<String> = []
    private var invitationTasksByPeerID: [String: Task<Void, Never>] = [:]
    private var isMediaActive = false

    init(displayName: String) {
        self.localPeerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        self.session.delegate = self
    }

    func connect(group: CallGroup) {
        stopDiscoveryAndSession()
        credential = LocalDiscoveryInfo.credential(for: group)
        handshakeRegistry = credential.map(HandshakeRegistry.init(credential:))
        sequencer = AudioPacketSequencer(groupID: group.id)
        receivedPacketFilter = ReceivedAudioPacketFilter(groupID: group.id)
        receivedPackets.removeAll()
        resetInvitationState()
        isMediaActive = false
        notify(.localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing)))

        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: credential.map(LocalDiscoveryInfo.makeDiscoveryInfo(for:)),
            serviceType: LocalNetworkConfiguration.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: LocalNetworkConfiguration.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func disconnect() {
        stopDiscoveryAndSession()
        credential = nil
        handshakeRegistry = nil
        sequencer = nil
        receivedPacketFilter = nil
        receivedPackets.removeAll()
        resetInvitationState()
        isMediaActive = false
        notify(.disconnected)
    }

    func startMedia() {
        isMediaActive = true
    }

    func stopMedia() {
        isMediaActive = false
        receivedPackets.removeAll()
    }

    func sendAudioFrame(_ frame: OutboundAudioPacket) {
        guard isMediaActive else { return }
        send(frame)
    }

    func sendConnectionKeepalive() {
        send(.keepalive)
    }

    func sendApplicationData(_ message: ApplicationDataMessage) {
        send(message)
    }

    private func send(_ message: RouteControlMessage, toPeers peers: [MCPeerID]? = nil) {
        let targetPeers = peers ?? session.connectedPeers
        guard !targetPeers.isEmpty else { return }

        do {
            let payload = try MultipeerPayloadBuilder.makePayload(for: message)
            try session.send(payload.data, toPeers: targetPeers, with: payload.mcMode)
        } catch {
            logger.error("Failed to send control payload: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func send(_ message: ApplicationDataMessage, toPeers peers: [MCPeerID]? = nil) {
        let targetPeers = peers ?? session.connectedPeers
        guard !targetPeers.isEmpty else { return }

        do {
            let payload = try MultipeerPayloadBuilder.makePayload(for: message)
            try session.send(payload.data, toPeers: targetPeers, with: payload.mcMode)
        } catch {
            logger.error("Failed to send application data payload: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func send(_ packet: OutboundAudioPacket) {
        guard !session.connectedPeers.isEmpty, var sequencer else { return }

        do {
            let result = try MultipeerPayloadBuilder.makePayload(
                for: packet,
                sequencer: &sequencer,
                credential: credential
            )
            self.sequencer = sequencer
            notify(.outboundPacketBuilt(OutboundPacketDiagnostics(
                route: route,
                streamID: result.envelope.streamID,
                sequenceNumber: result.envelope.sequenceNumber,
                packetKind: result.envelope.kind,
                metadata: result.transmitMetadata
            )))
            try session.send(result.payload.data, toPeers: session.connectedPeers, with: result.payload.mcMode)
        } catch {
            logger.error("Failed to send audio payload: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopDiscoveryAndSession() {
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        session.disconnect()
        browser = nil
        advertiser = nil
    }

    private func notify(_ event: TransportEvent) {
        let event = event.withLocalNetworkTimestampIfNeeded()
        Task { @MainActor [weak self] in
            self?.onEvent?(event)
        }
    }

    private func resetInvitationState() {
        pendingOutgoingInvitationPeerIDs.removeAll()
        invitationTasksByPeerID.values.forEach { $0.cancel() }
        invitationTasksByPeerID.removeAll()
    }

    private func scheduleInvitation(
        for peerID: MCPeerID,
        credential: GroupAccessCredential,
        browser: MCNearbyServiceBrowser
    ) {
        let peerDisplayName = peerID.displayName
        guard invitationTasksByPeerID[peerDisplayName] == nil,
              !pendingOutgoingInvitationPeerIDs.contains(peerDisplayName),
              !session.connectedPeers.contains(peerID) else { return }

        let delayNanoseconds = invitationDelayNanoseconds(for: peerID)
        invitationTasksByPeerID[peerDisplayName] = Task { [weak self, weak browser] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  let browser else { return }

            self.invitationTasksByPeerID[peerDisplayName] = nil
            guard self.credential == credential,
                  !self.pendingOutgoingInvitationPeerIDs.contains(peerDisplayName),
                  !self.session.connectedPeers.contains(peerID) else { return }

            self.pendingOutgoingInvitationPeerIDs.insert(peerDisplayName)
            self.notify(.localNetworkStatus(LocalNetworkEvent(status: .invited, peerID: peerDisplayName)))
            browser.invitePeer(
                peerID,
                to: self.session,
                withContext: LocalInvitationContext(groupHash: credential.groupHash).encoded,
                timeout: 10
            )
        }
    }

    private func invitationDelayNanoseconds(for peerID: MCPeerID) -> UInt64 {
        let pairKey = [localPeerID.displayName, peerID.displayName].sorted().joined(separator: "|")
        let pairJitter = UInt64(abs(pairKey.hashValue) % 180_000_000)
        let roleOffset: UInt64 = localPeerID.displayName < peerID.displayName ? 120_000_000 : 360_000_000
        return roleOffset + pairJitter
    }
}

private extension TransportEvent {
    func withLocalNetworkTimestampIfNeeded(now: TimeInterval = Date().timeIntervalSince1970) -> TransportEvent {
        guard case .localNetworkStatus(let event) = self,
              event.occurredAt == nil else { return self }

        return .localNetworkStatus(LocalNetworkEvent(
            status: event.status,
            peerID: event.peerID,
            occurredAt: now
        ))
    }
}

extension MultipeerLocalTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard peerID != localPeerID else { return }
        guard let credential,
              LocalDiscoveryInfo.matches(info, credential: credential) else {
            notify(.localNetworkStatus(LocalNetworkEvent(status: .rejected(.groupMismatch), peerID: peerID.displayName)))
            return
        }
        scheduleInvitation(for: peerID, credential: credential, browser: browser)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        invitationTasksByPeerID.removeValue(forKey: peerID.displayName)?.cancel()
        pendingOutgoingInvitationPeerIDs.remove(peerID.displayName)
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        notify(.localNetworkStatus(LocalNetworkEvent(status: .unavailable)))
        notify(.linkFailed(internetAvailable: false))
    }
}

extension MultipeerLocalTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard let credential,
              LocalInvitationContext.decode(context)?.groupHash == credential.groupHash else {
            notify(.localNetworkStatus(LocalNetworkEvent(status: .rejected(.groupMismatch), peerID: peerID.displayName)))
            invitationHandler(false, nil)
            return
        }

        notify(.localNetworkStatus(LocalNetworkEvent(status: .invitationReceived, peerID: peerID.displayName)))
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        notify(.localNetworkStatus(LocalNetworkEvent(status: .unavailable)))
        notify(.linkFailed(internetAvailable: false))
    }
}

extension MultipeerLocalTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        invitationTasksByPeerID.removeValue(forKey: peerID.displayName)?.cancel()

        switch state {
        case .connected:
            pendingOutgoingInvitationPeerIDs.remove(peerID.displayName)
            if let credential {
                send(
                    .handshake(HandshakeMessage.make(credential: credential, memberID: localPeerID.displayName)),
                    toPeers: [peerID]
                )
            }
            notify(.localNetworkStatus(LocalNetworkEvent(status: .connected, peerID: peerID.displayName)))
            notify(.connected(peerIDs: session.connectedPeers.map(\.displayName)))
        case .connecting:
            break
        case .notConnected:
            pendingOutgoingInvitationPeerIDs.remove(peerID.displayName)
            notify(session.connectedPeers.isEmpty ? .disconnected : .connected(peerIDs: session.connectedPeers.map(\.displayName)))
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if handleControlPayload(data, fromPeer: peerID) {
            return
        }

        guard handshakeRegistry?.isAuthenticated(peerID: peerID.displayName) == true else { return }

        if handleApplicationDataPayload(data, fromPeer: peerID) {
            return
        }

        guard isMediaActive,
              var filter = receivedPacketFilter else { return }

        do {
            let envelope = try MultipeerPayloadBuilder.decodeAudioPayload(data, credential: credential)
            guard let received = filter.accept(envelope, fromPeerID: peerID.displayName) else {
                receivedPacketFilter = filter
                return
            }
            receivedPacketFilter = filter
            receivedPackets.append(received)
            notify(.receivedPacket(received))
        } catch {
            receivedPacketFilter = filter
        }
    }

    private func handleApplicationDataPayload(_ data: Data, fromPeer peerID: MCPeerID) -> Bool {
        guard let message = try? MultipeerPayloadBuilder.decodeApplicationDataPayload(data) else { return false }
        notify(.receivedApplicationData(peerID: peerID.displayName, message: message))
        return true
    }

    private func handleControlPayload(_ data: Data, fromPeer peerID: MCPeerID) -> Bool {
        guard let message = try? MultipeerPayloadBuilder.decodeControlPayload(data) else { return false }

        switch message {
        case .keepalive:
            return true
        case .handshake(let handshake):
            guard var registry = handshakeRegistry else { return true }
            switch registry.accept(handshake, fromPeerID: peerID.displayName) {
            case .accepted:
                handshakeRegistry = registry
                notify(.authenticated(peerIDs: registry.authenticatedPeerIDs))
            case .rejected:
                notify(.localNetworkStatus(LocalNetworkEvent(status: .rejected(.handshakeInvalid), peerID: peerID.displayName)))
                session.cancelConnectPeer(peerID)
            }
            return true
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

private extension MultipeerPayload {
    var mcMode: MCSessionSendDataMode {
        switch mode {
        case .unreliable:
            .unreliable
        case .reliable:
            .reliable
        }
    }
}

private struct LocalInvitationContext: Codable, Equatable {
    let groupHash: String

    var encoded: Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data?) -> LocalInvitationContext? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
#endif
