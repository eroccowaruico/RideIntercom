import Foundation
import RTC

#if canImport(WebRTC)
@preconcurrency import WebRTC

public final class WebRTCNativeEngine: NativeWebRTCEngine, @unchecked Sendable {
    public override var isAvailable: Bool { true }

    private let factory: RTCPeerConnectionFactory
    private let rtcConfiguration: RTCConfiguration
    private let lock = NSRecursiveLock()
    private var localAudioTrack: RTCAudioTrack?
    private var outputMuted = false
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

    public init(iceServers: [WebRTCIceServer]) {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        self.rtcConfiguration = configuration
        super.init()
    }

    public override func prepareLocalAudio(peer: PeerDescriptor, policy: RTCAudioPolicy) async {
        _ = policy
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: audioSource, trackId: "rideintercom-audio-\(peer.id.rawValue)")
        track.isEnabled = false
        lock.withLock { localAudioTrack = track }
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

        if let localAudioTrack {
            if let sender = connection.add(localAudioTrack, streamIds: ["rideintercom-audio"]) {
                let parameters = sender.parameters
                for encoding in parameters.encodings { encoding.maxBitrateBps = 32_000 }
                sender.parameters = parameters
            }
        }

        // Application messages use the authenticated Worker socket; only audio reaches SFU.
        peerConnections[peer.id] = connection
        peerIDsByConnection[ObjectIdentifier(connection)] = peer.id
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

    public override func setLocalAudioEnabled(_ enabled: Bool) async {
        lock.withLock { localAudioTrack?.isEnabled = enabled }
    }

    public override func setOutputMuted(_ muted: Bool) async {
        lock.withLock {
        outputMuted = muted
        for connection in peerConnections.values {
            for receiver in connection.receivers { receiver.track?.isEnabled = !muted }
        }
        }
    }

    public override func closePeerConnection(peerID: PeerID) async {
        let connection = lock.withLock {
            let connection = peerConnections.removeValue(forKey: peerID)
            if let connection { peerIDsByConnection.removeValue(forKey: ObjectIdentifier(connection)) }
            return connection
        }
        connection?.close()
    }

    public override func close() async {
        let connections = lock.withLock {
            let connections = Array(peerConnections.values)
            peerConnections.removeAll()
            peerIDsByConnection.removeAll()
            localAudioTrack = nil
            return connections
        }
        // WebRTC may synchronously call its delegate while closing.
        connections.forEach { $0.close() }
    }
}

extension WebRTCNativeEngine: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        lock.withLock {
            guard peerIDsByConnection[ObjectIdentifier(peerConnection)] != nil else { return }
            stream.audioTracks.forEach { $0.isEnabled = !outputMuted }
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        lock.withLock {
            guard peerIDsByConnection[ObjectIdentifier(peerConnection)] != nil else { return }
            rtpReceiver.track?.isEnabled = !outputMuted
        }
    }
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
