import Foundation
import RTC

#if canImport(WebRTC)
@preconcurrency import WebRTC

public final class WebRTCNativeEngine: NativeWebRTCEngine {
    public override var isAvailable: Bool { true }
    public override var events: AsyncStream<WebRTCEngineEvent> { eventStream }

    private let factory: RTCPeerConnectionFactory
    private let rtcConfiguration: RTCConfiguration
    private let eventStream: AsyncStream<WebRTCEngineEvent>
    private let eventContinuation: AsyncStream<WebRTCEngineEvent>.Continuation
    private var localAudioTrack: RTCAudioTrack?
    private var peerConnections: [PeerID: RTCPeerConnection] = [:]
    private var dataChannels: [PeerID: RTCDataChannel] = [:]
    private var peerIDsByConnection = [ObjectIdentifier: PeerID]()
    private var peerIDsByDataChannel = [ObjectIdentifier: PeerID]()

    public override init() {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory()
        self.rtcConfiguration = RTCConfiguration()
        var continuation: AsyncStream<WebRTCEngineEvent>.Continuation?
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation!
        super.init()
    }

    public init(iceServers: [WebRTCIceServer]) {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        self.rtcConfiguration = configuration
        var continuation: AsyncStream<WebRTCEngineEvent>.Continuation?
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation!
        super.init()
    }

    public override func prepareLocalAudio(peer: PeerDescriptor, policy: RTCAudioPolicy) async {
        _ = policy
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: audioSource, trackId: "rideintercom-audio-\(peer.id.rawValue)")
        track.isEnabled = false
        localAudioTrack = track
    }

    public override func createPeerConnection(for peer: PeerDescriptor) async {
        guard peerConnections[peer.id] == nil else { return }

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: self
        ) else { return }

        if let localAudioTrack {
            _ = connection.add(localAudioTrack, streamIds: ["rideintercom-audio"])
        }

        let channelConfiguration = RTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        let channel = connection.dataChannel(forLabel: "rideintercom.application", configuration: channelConfiguration)
        channel?.delegate = self

        peerConnections[peer.id] = connection
        if let channel {
            dataChannels[peer.id] = channel
            peerIDsByDataChannel[ObjectIdentifier(channel)] = peer.id
        }
        peerIDsByConnection[ObjectIdentifier(connection)] = peer.id
    }

    public override func makeOffer(for peerID: PeerID) async -> WebRTCSessionDescription? {
        guard let connection = peerConnections[peerID] else { return nil }
        guard let sdp = await connection.makeAndSetLocalOfferSDP() else { return nil }
        return WebRTCSessionDescription(kind: .offer, sdp: sdp)
    }

    public override func acceptOffer(_ offer: WebRTCSessionDescription, from peerID: PeerID) async -> WebRTCSessionDescription? {
        guard let connection = peerConnections[peerID] else { return nil }
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: offer.sdp)
        guard await connection.rtcSetRemoteDescription(remoteDescription) else { return nil }
        guard let sdp = await connection.makeAndSetLocalAnswerSDP() else { return nil }
        return WebRTCSessionDescription(kind: .answer, sdp: sdp)
    }

    public override func acceptAnswer(_ answer: WebRTCSessionDescription, from peerID: PeerID) async {
        let description = RTCSessionDescription(type: .answer, sdp: answer.sdp)
        _ = await peerConnections[peerID]?.rtcSetRemoteDescription(description)
    }

    public override func addCandidate(_ candidate: WebRTCIceCandidate, from peerID: PeerID) async {
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        await peerConnections[peerID]?.addIceCandidate(rtcCandidate)
    }

    public override func setLocalAudioEnabled(_ enabled: Bool) async {
        localAudioTrack?.isEnabled = enabled
    }

    public override func sendApplicationData(_ message: ApplicationDataMessage) async -> Bool {
        guard let data = try? JSONEncoder().encode(message) else { return false }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        var didSend = false
        for channel in dataChannels.values where channel.readyState == .open {
            didSend = channel.sendData(buffer) || didSend
        }
        return didSend
    }

    public override func closePeerConnection(peerID: PeerID) async {
        if let channel = dataChannels.removeValue(forKey: peerID) {
            peerIDsByDataChannel.removeValue(forKey: ObjectIdentifier(channel))
            channel.close()
        }
        if let connection = peerConnections.removeValue(forKey: peerID) {
            peerIDsByConnection.removeValue(forKey: ObjectIdentifier(connection))
            connection.close()
        }
    }

    public override func close() async {
        dataChannels.values.forEach { $0.close() }
        peerConnections.values.forEach { $0.close() }
        dataChannels.removeAll()
        peerConnections.removeAll()
        peerIDsByConnection.removeAll()
        peerIDsByDataChannel.removeAll()
        localAudioTrack = nil
    }
}

extension WebRTCNativeEngine: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        eventContinuation.yield(.connectionStateChanged(newState.routeState))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let peerID = peerIDsByConnection[ObjectIdentifier(peerConnection)] else { return }
        eventContinuation.yield(.localIceCandidate(WebRTCIceCandidate(candidate), peerID: peerID))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        if let peerID = peerIDsByConnection[ObjectIdentifier(peerConnection)] {
            dataChannels[peerID] = dataChannel
            peerIDsByDataChannel[ObjectIdentifier(dataChannel)] = peerID
        }
    }
}

extension WebRTCNativeEngine: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let peerID = peerIDsByDataChannel[ObjectIdentifier(dataChannel)],
              let message = try? JSONDecoder().decode(ApplicationDataMessage.self, from: buffer.data) else { return }
        eventContinuation.yield(.receivedApplicationData(ReceivedApplicationData(peerID: peerID, message: message)))
    }
}

private extension RTCPeerConnection {
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

private extension WebRTCIceCandidate {
    init(_ candidate: RTCIceCandidate) {
        self.init(
            sdp: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex)
        )
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
public final class WebRTCNativeEngine: NativeWebRTCEngine {
    public override var isAvailable: Bool { false }

    public override init() {
        super.init()
    }
}
#endif
