import Foundation

#if os(iOS)
import UIKit
#endif

#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

final class MultipeerLocalTransport: NSObject, Transport {
    let route: TransportRoute = .local
    var onEvent: (@MainActor (TransportEvent) -> Void)?

    private let localPeerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var connectedGroup: IntercomGroup?
    private var credential: GroupAccessCredential?
    private var handshakeRegistry: HandshakeRegistry?
    private var sequencer: AudioPacketSequencer?
    private var receivedPacketFilter: ReceivedAudioPacketFilter?
    private var preferredAudioCodec: AudioCodecIdentifier = .pcm16
    private var heAACv2Quality: HEAACv2Quality = .medium
    private(set) var receivedPackets: [ReceivedAudioPacket] = []

    init(displayName: String = MultipeerLocalTransport.defaultDisplayName) {
        self.localPeerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        self.session.delegate = self
    }

    private static var defaultDisplayName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "RideIntercom"
        #endif
    }

    func connect(group: IntercomGroup) {
        connectedGroup = group
        credential = LocalDiscoveryInfo.credential(for: group)
        handshakeRegistry = credential.map(HandshakeRegistry.init(credential:))
        sequencer = AudioPacketSequencer(groupID: group.id)
        receivedPacketFilter = ReceivedAudioPacketFilter(groupID: group.id)
        receivedPackets.removeAll()
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
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        session.disconnect()
        browser = nil
        advertiser = nil
        connectedGroup = nil
        credential = nil
        handshakeRegistry = nil
        sequencer = nil
        receivedPacketFilter = nil
        receivedPackets.removeAll()
        notify(.disconnected)
    }

    func sendAudioFrame(_ frame: OutboundAudioPacket) {
        send(frame)
    }

    func sendControl(_ message: ControlMessage) {
        switch message {
        case .keepalive:
            send(OutboundAudioPacket.keepalive)
        case .handshake, .peerMuteState:
            send(message)
        }
    }

    func setPreferredAudioCodec(_ codec: AudioCodecIdentifier) {
        preferredAudioCodec = codec
    }

    func setHEAACv2Quality(_ quality: HEAACv2Quality) {
        heAACv2Quality = quality
    }

    private func send(_ message: ControlMessage, toPeers peers: [MCPeerID]? = nil) {
        let targetPeers = peers ?? session.connectedPeers
        guard !targetPeers.isEmpty else { return }

        do {
            let payload = try MultipeerPayloadBuilder.makePayload(for: message)
            try session.send(payload.data, toPeers: targetPeers, with: payload.mcMode)
        } catch {
        }
    }

    private func send(_ packet: OutboundAudioPacket) {
        guard !session.connectedPeers.isEmpty, var sequencer else { return }
        sequencer.codec = preferredAudioCodec
        sequencer.heAACv2Quality = heAACv2Quality

        do {
            let payload = try MultipeerPayloadBuilder.makePayload(
                for: packet,
                sequencer: &sequencer,
                credential: credential
            )
            self.sequencer = sequencer
            try session.send(payload.data, toPeers: session.connectedPeers, with: payload.mcMode)
        } catch {
        }
    }

    private func notify(_ event: TransportEvent) {
        let event = event.withLocalNetworkTimestampIfNeeded()
        Task { @MainActor [weak self] in
            self?.onEvent?(event)
        }
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

extension MultipeerLocalTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard peerID != localPeerID else { return }
        guard let credential,
              LocalDiscoveryInfo.matches(info, credential: credential) else {
            notify(.localNetworkStatus(LocalNetworkEvent(status: .rejected(.groupMismatch), peerID: peerID.displayName)))
            return
        }

        notify(.localNetworkStatus(LocalNetworkEvent(status: .invited, peerID: peerID.displayName)))
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

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
        switch state {
        case .connected:
            if let credential {
                send(
                    .handshake(HandshakeService.makeMessage(credential: credential, memberID: localPeerID.displayName)),
                    toPeers: [peerID]
                )
            }
            notify(.localNetworkStatus(LocalNetworkEvent(status: .connected, peerID: peerID.displayName)))
            notify(.connected(peerIDs: session.connectedPeers.map(\.displayName)))
        case .connecting:
            break
        case .notConnected:
            notify(session.connectedPeers.isEmpty ? .disconnected : .connected(peerIDs: session.connectedPeers.map(\.displayName)))
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if handleControlPayload(data, fromPeer: peerID) {
            return
        }

        guard handshakeRegistry?.isAuthenticated(peerID: peerID.displayName) == true,
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
        case .peerMuteState(let isMuted):
            notify(.remotePeerMuteState(peerID: peerID.displayName, isMuted: isMuted))
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

enum DefaultLocalTransportFactory {
    static func make(displayName: String) -> Transport {
        MultipeerLocalTransport(displayName: displayName)
    }
}
#else
enum DefaultLocalTransportFactory {
    static func make(displayName: String) -> Transport {
        LocalTransport()
    }
}
#endif