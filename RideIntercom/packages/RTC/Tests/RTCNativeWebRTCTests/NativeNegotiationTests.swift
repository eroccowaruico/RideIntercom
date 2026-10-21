import Foundation
import Testing
import RTC
import RTCNativeWebRTC

@Test func nativeSDPUsesAudioOnlyAndReportsRejectedAnswers() async throws {
    let engine = WebRTCNativeEngine(iceServers: [])
    let peer = PeerDescriptor(id: .init(rawValue: "native-check"), displayName: "Native")
    #expect(engine.isAvailable)
    for _ in 0..<2 {
        await engine.prepareLocalAudio(peer: peer, policy: RTCAudioPolicy())
        await engine.createPeerConnection(for: peer)
        let offer = try #require(await engine.makeOffer(for: peer.id))
        #expect(offer.sdp.contains("m=audio"))
        #expect(offer.sdp.lowercased().contains("opus/48000"))
        #expect(!offer.sdp.contains("m=video"))
        #expect(!offer.sdp.contains("m=application"))
        #expect(await !engine.acceptAnswer(.init(kind: .answer, sdp: "invalid"), from: peer.id))
        await engine.close(); await engine.close()
        #expect(await engine.makeOffer(for: peer.id) == nil)
    }
}
