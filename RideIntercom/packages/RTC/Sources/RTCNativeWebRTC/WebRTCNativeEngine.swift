import Foundation
import RTC

#if canImport(WebRTC)
@preconcurrency import WebRTC

public final class WebRTCNativeEngine: NativeWebRTCEngine, @unchecked Sendable {
    public override var isAvailable: Bool { true }

    private let factory: RTCPeerConnectionFactory
    private var rtcConfiguration: RTCConfiguration
    private let lock = NSRecursiveLock()
    private var channels: [PeerID: [Int32: RTCDataChannel]] = [:]
    private var channelOrigins: [ObjectIdentifier: PeerID] = [:]
    private var publishers: [PeerID: [ApplicationDataDelivery: Int32]] = [:]
    private var peerConnections: [PeerID: RTCPeerConnection] = [:]
    private var peerIDsByConnection = [ObjectIdentifier: PeerID]()

    public override init() {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory()
        self.rtcConfiguration = RTCConfiguration()
        self.rtcConfiguration.sdpSemantics = .unifiedPlan
        self.rtcConfiguration.iceServers = [RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])]
        super.init()
    }

    public init(iceServers: [WebRTCIceServer], factory: RTCPeerConnectionFactory = RTCPeerConnectionFactory()) {
        RTCInitializeSSL()
        self.factory = factory
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        self.rtcConfiguration = configuration
        super.init()
    }

    public override func createPeerConnection(for peer: PeerDescriptor) async {
        lock.withLock {
        guard peerConnections[peer.id] == nil else { return }

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: self
        ) else { return }

        // Reserve a negotiated control channel to put SCTP in the initial SDP.
        // It never carries audio; the Worker returns the actual SFU allocations.
        let bootstrap = RTCDataChannelConfiguration()
        bootstrap.isNegotiated = true; bootstrap.channelId = 0
        if let channel = connection.dataChannel(forLabel: "server-events", configuration: bootstrap) {
            channels[peer.id] = [0: channel]
        }
        peerConnections[peer.id] = connection
        peerIDsByConnection[ObjectIdentifier(connection)] = peer.id
        }
    }

    public override func configureIceServers(_ servers: [WebRTCIceServer]) async -> Bool {
        guard !servers.isEmpty, servers.allSatisfy({ !$0.urls.isEmpty }) else { return false }
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        let connections = lock.withLock {
            rtcConfiguration = configuration
            return Array(peerConnections.values)
        }
        // Refresh credentials on the existing connection without replacing its channels.
        return connections.allSatisfy { $0.setConfiguration(configuration) }
    }

    public override func networkStatistics(for peerID: PeerID) async -> RTCNetworkStatistics {
        guard let connection = lock.withLock({ peerConnections[peerID] }) else { return .init() }
        let result: RTCNetworkStatistics = await withCheckedContinuation { continuation in
            connection.statistics { report in
                let selected = report.statistics.values.first { $0.type == "transport" }?.values["selectedCandidatePairId"] as? String
                let pair = selected.flatMap { report.statistics[$0] }
                let rtt = (pair?.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
                continuation.resume(returning: .init(roundTripTime: rtt,
                    unavailableReason: "SCTP DataChannel packet loss is not exposed; RTT is ICE transport RTT"))
            }
        }
        return lock.withLock {
            guard peerConnections[peerID] === connection else { return .init() }
            var current = result
            current.bufferedBytes = channels[peerID]?.values.reduce(UInt64(0)) { $0 + $1.bufferedAmount }
            return current
        }
    }

    public override func makeOffer(for peerID: PeerID) async -> WebRTCSessionDescription? {
        guard let connection = lock.withLock({ peerConnections[peerID] }) else { return nil }
        guard let sdp = await connection.makeAndSetLocalOfferSDP() else { return nil }
        return WebRTCSessionDescription(kind: .offer, sdp: await connection.gatheredSDP(fallback: sdp))
    }

    public override func acceptOffer(_ offer: WebRTCSessionDescription, from peerID: PeerID) async -> WebRTCSessionDescription? {
        guard let connection = lock.withLock({ peerConnections[peerID] }) else { return nil }
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: offer.sdp)
        guard await connection.rtcSetRemoteDescription(remoteDescription) else { return nil }
        guard let sdp = await connection.makeAndSetLocalAnswerSDP() else { return nil }
        return WebRTCSessionDescription(kind: .answer, sdp: await connection.gatheredSDP(fallback: sdp))
    }

    public override func acceptAnswer(_ answer: WebRTCSessionDescription, from peerID: PeerID) async -> Bool {
        guard let connection = lock.withLock({ peerConnections[peerID] }) else { return false }
        let description = RTCSessionDescription(type: .answer, sdp: answer.sdp)
        return await connection.rtcSetRemoteDescription(description)
    }

    public override func addCandidate(_ candidate: WebRTCIceCandidate, from peerID: PeerID) async {
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        let connection = lock.withLock { peerConnections[peerID] }
        await connection?.addIceCandidate(rtcCandidate)
    }

    public override func configureDataChannels(_ allocations: [WebRTCDataChannel], for peerID: PeerID) async {
        guard let connection = lock.withLock({ peerConnections[peerID] }) else { return }
        let wanted = Set(allocations.map(\.id))
        let obsolete: [RTCDataChannel] = lock.withLock {
            let old = channels[peerID, default: [:]].filter { !wanted.contains($0.key) }.map(\.value)
            for channel in old {
                channelOrigins[ObjectIdentifier(channel)] = nil; channels[peerID]?[channel.channelId] = nil
            }
            publishers[peerID] = nil
            return old
        }
        // RTC callbacks can be synchronous. Never hold our lock across SDK mutations.
        for channel in obsolete { channel.delegate = nil; channel.close() }
        for allocation in allocations {
            let config = RTCDataChannelConfiguration()
            config.isNegotiated = true; config.channelId = allocation.id
            if allocation.delivery == .unreliable { config.isOrdered = false; config.maxRetransmits = 0 }
            let existing = lock.withLock { channels[peerID]?[allocation.id] }
            guard let channel = existing ?? connection.dataChannel(forLabel: "rideintercom", configuration: config) else { continue }
            let retained = lock.withLock {
                guard peerConnections[peerID] === connection else { return false }
                channels[peerID, default: [:]][allocation.id] = channel
                if allocation.isPublisher { publishers[peerID, default: [:]][allocation.delivery] = allocation.id }
                if let origin = allocation.peerID { channelOrigins[ObjectIdentifier(channel)] = origin }
                return true
            }
            if retained { channel.delegate = self } else { channel.close() }
        }
    }

    public override func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID) async {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        guard let data = try? encoder.encode(message), data.count <= 49152 else { return }
        let channel = lock.withLock { publishers[peerID]?[message.delivery].flatMap { channels[peerID]?[$0] } }
        guard let channel, channel.readyState == .open,
              (message.delivery == .reliable ? channel.bufferedAmount <= 65536 : channel.bufferedAmount == 0) else { return }
        _ = channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    public override func closePeerConnection(peerID: PeerID) async {
        let owned = lock.withLock { () -> (RTCPeerConnection?, [RTCDataChannel]) in
            let old = Array(channels.removeValue(forKey: peerID)?.values ?? [:].values)
            for channel in old { channelOrigins[ObjectIdentifier(channel)] = nil }
            publishers[peerID] = nil
            let connection = peerConnections.removeValue(forKey: peerID)
            if let connection { peerIDsByConnection.removeValue(forKey: ObjectIdentifier(connection)) }
            return (connection, old)
        }
        for channel in owned.1 { channel.delegate = nil; channel.close() }
        owned.0?.close()
    }
    public override func close() async {
        let ids = lock.withLock { Array(peerConnections.keys) }
        for id in ids { await closePeerConnection(peerID: id) }
    }

}

extension WebRTCNativeEngine: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        lock.withLock {
            guard peerIDsByConnection[ObjectIdentifier(peerConnection)] != nil else { return }
            emit(.connectionStateChanged(newState.routeState))
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Offers/answers include gathered ICE. No unused trickle or DataChannel path.
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { dataChannel.close() }
}

extension WebRTCNativeEngine: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        let publishing = lock.withLock { publishers.values.contains { $0[.unreliable] == dataChannel.channelId } }
        if publishing { emit(.connectionStateChanged(.mediaReady)) }
    }
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary, buffer.data.count <= 49152,
              let message = try? PropertyListDecoder().decode(ApplicationDataMessage.self, from: buffer.data) else { return }
        lock.withLock {
            guard let origin = channelOrigins[ObjectIdentifier(dataChannel)] else { return }
            emit(.receivedApplicationData(.init(peerID: origin, message: message)))
        }
    }
}

private extension RTCPeerConnection {
    func gatheredSDP(fallback: String) async -> String {
        for _ in 0..<100 {
            if iceGatheringState == .complete || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return localDescription?.sdp ?? fallback
    }

    func makeAndSetLocalOfferSDP() async -> String? {
        await withCheckedContinuation { continuation in
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            offer(for: constraints) { description, _ in
                guard let description else {
                    continuation.resume(returning: nil)
                    return
                }
                self.setLocalDescription(description) { error in
                    continuation.resume(returning: error == nil ? description.sdp : nil)
                }
            }
        }
    }

    func makeAndSetLocalAnswerSDP() async -> String? {
        await withCheckedContinuation { continuation in
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            answer(for: constraints) { description, _ in
                guard let description else {
                    continuation.resume(returning: nil)
                    return
                }
                self.setLocalDescription(description) { error in
                    continuation.resume(returning: error == nil ? description.sdp : nil)
                }
            }
        }
    }

    func rtcSetRemoteDescription(_ description: RTCSessionDescription) async -> Bool {
        await withCheckedContinuation { continuation in
            setRemoteDescription(description) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    func addIceCandidate(_ candidate: RTCIceCandidate) async {
        await withCheckedContinuation { continuation in
            add(candidate) { _ in
                continuation.resume()
            }
        }
    }
}

private extension RTCIceConnectionState {
    var routeState: RouteConnectionState {
        switch self {
        case .connected, .completed:
            .connected
        case .checking, .new:
            .connecting
        case .failed:
            .failed
        case .disconnected, .closed, .count:
            .disconnected
        @unknown default:
            .failed
        }
    }
}
#else
public final class WebRTCNativeEngine: NativeWebRTCEngine, @unchecked Sendable {
    public override var isAvailable: Bool { false }

    public override init() {
        super.init()
    }
}
#endif
