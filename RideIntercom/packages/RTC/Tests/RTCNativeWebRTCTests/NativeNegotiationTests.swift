import Foundation
import Testing
import RTC
import RTCNativeWebRTC
@preconcurrency import WebRTC

@Test func nativeSDPUsesPacketTransportAndReportsRejectedAnswers() async throws {
    let engine = WebRTCNativeEngine(iceServers: [])
    let peer = PeerDescriptor(id: .init(rawValue: "native-check"), displayName: "Native")
    #expect(engine.isAvailable)
    for _ in 0..<2 {
        await engine.prepareLocalAudio(peer: peer, policy: RTCAudioPolicy())
        await engine.createPeerConnection(for: peer)
        let offer = try #require(await engine.makeOffer(for: peer.id))
        #expect(!offer.sdp.contains("m=audio"))
        #expect(offer.sdp.contains("a=sctp-port:5000"))
        #expect(!offer.sdp.contains("m=video"))
        #expect(offer.sdp.contains("m=application"))
        #expect(await !engine.acceptAnswer(.init(kind: .answer, sdp: "invalid"), from: peer.id))
        await engine.close(); await engine.close()
        #expect(await engine.makeOffer(for: peer.id) == nil)
    }
}

private actor PacketRecorder {
    var messages: [ApplicationDataMessage] = []
    var states: [RouteConnectionState] = []
    func record(_ event: WebRTCEngineEvent) {
        if case .connectionStateChanged(let state) = event { states.append(state) }
        if case .receivedApplicationData(let data) = event { messages.append(data.message) }
    }
}

@Test(.timeLimit(.minutes(1))) func nativePairTransfersEncodedAudioInBothDirectionsWithoutMicrophone() async throws {
    func endpoint() -> WebRTCNativeEngine {
        let factory = RTCPeerConnectionFactory()
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreLoopbackNetworkAdapter = false
        factory.setOptions(options)
        return WebRTCNativeEngine(iceServers: [], factory: factory)
    }
    let a = endpoint(), b = endpoint()
    let peer = PeerDescriptor(id: .init(rawValue: "connection"), displayName: "Connection")
    let ar = PacketRecorder(), br = PacketRecorder()
    let ae = a.events, be = b.events
    let at = Task { for await e in ae { await ar.record(e) } }, bt = Task { for await e in be { await br.record(e) } }
    defer { at.cancel(); bt.cancel() }
    await a.createPeerConnection(for: peer); await b.createPeerConnection(for: peer)
    await a.configureDataChannels([.init(id: 2, isPublisher: true), .init(id: 4, peerID: .init(rawValue: "b"))], for: peer.id)
    await b.configureDataChannels([.init(id: 4, isPublisher: true), .init(id: 2, peerID: .init(rawValue: "a"))], for: peer.id)
    let offer = try #require(await a.makeOffer(for: peer.id))
    let answer = try #require(await b.acceptOffer(offer, from: peer.id))
    #expect(await a.acceptAnswer(answer, from: peer.id))
    let audio = RTCAudioPacket(sequenceNumber: 1, codec: .pcm16, format: .init(sampleRate: 16000, channelCount: 1), payload: Data(repeating: 42, count: 640))
    let message = ApplicationDataMessage(namespace: "encoded-audio", payload: try JSONEncoder().encode(audio), delivery: .unreliable)
    for _ in 0..<200 {
        await a.sendApplicationData(message, to: peer.id); await b.sendApplicationData(message, to: peer.id)
        let aReady = await !ar.messages.isEmpty, bReady = await !br.messages.isEmpty
        if aReady && bReady { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let asText = await ar.states, bsText = await br.states
    #expect(await ar.messages.contains(message), "A states: \(asText)"); #expect(await br.messages.contains(message), "B states: \(bsText)")
    await a.close(); await b.close()
}
