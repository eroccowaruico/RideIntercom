import Foundation
import Testing
@testable import RTC

@Suite struct RelayContractTests {
    let credential = RTCCredential.derived(groupID: "group", secret: "secret")
    func relay(_ id: String, codecs: [RTCAudioCodecIdentifier] = [.pcm16, .opus], credential: RTCCredential? = nil) -> GroupRelay {
        GroupRelay(request: .init(sessionID: "group", localPeer: .init(id: .init(rawValue: id), displayName: id),
                                 credential: credential ?? self.credential, audioPolicy: .init(preferredCodecs: codecs)))
    }
    @Test func codecAndFormatMetadataSurviveCommonEncryptedPath() throws {
        var a = relay("a"), b = relay("b", codecs: [.opus])
        let peer = PeerID(rawValue: "a")
        _ = b.receive(try a.make(.presence, now: 0), from: peer, now: 0)
        for format in [RTCAudioFormat(sampleRate: 24_000, channelCount: 2), .init(sampleRate: 48_000, channelCount: 1)] {
            let packet = RTCAudioPacket(sequenceNumber: 99, codec: .opus, format: format, capturedAt: 123,
                                        sampleCount: 480, bitRate: 32000, payload: Data([1, 2, 3]))
            let reception = try #require(b.receive(try a.make(.audio(packet), now: 1), from: peer, now: 1))
            guard case .audio(let received) = reception.body else { Issue.record("Missing audio"); return }
            #expect(received.codec == packet.codec && received.format == packet.format)
            #expect(received.capturedAt == packet.capturedAt && received.sampleCount == packet.sampleCount)
            #expect(received.bitRate == packet.bitRate && received.payload == packet.payload)
        }
        let unsupported = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, payload: Data([1]))
        #expect(b.receive(try a.make(.audio(unsupported), now: 1), from: peer, now: 1) == nil)
    }
    @Test func commonPathRejectsPlaintextWrongSecretAndRetiredEpoch() throws {
        let peer = PeerID(rawValue: "a")
        var a = relay("a"), b = relay("b")
        var wrong = relay("a", credential: .derived(groupID: "group", secret: "wrong"))
        var plain = GroupRelay(request: .init(sessionID: "group", localPeer: .init(id: peer, displayName: "a")))
        #expect(b.receive(try wrong.make(.presence, now: 0), from: peer, now: 0) == nil)
        #expect(b.receive(try plain.make(.presence, now: 0), from: peer, now: 0) == nil)
        let oldPresence = try a.make(.presence, now: 0)
        _ = b.receive(oldPresence, from: peer, now: 0)
        var restarted = relay("a")
        #expect(b.receive(try restarted.make(.presence, now: 1), from: peer, now: 1)?.didRestart == true)
        #expect(b.receive(oldPresence, from: peer, now: 1) == nil)
        #expect(b.receive(try a.make(.audio(.init(sequenceNumber: 0, codec: .pcm16, payload: Data([1]))), now: 1), from: peer, now: 1) == nil)
    }
    @Test func tenMinutesOfCommonDuplexAudioPreserveFramesAndBoundQueues() throws {
        var a = relay("a"), b = relay("b")
        var queueA = PacketAudioReceiveBuffer(), queueB = PacketAudioReceiveBuffer()
        let peerA = PeerID(rawValue: "a"), peerB = PeerID(rawValue: "b")
        var deliveredA = 0, deliveredB = 0
        func receive(_ data: Data, hop: PeerID, relay: inout GroupRelay, queue: inout PacketAudioReceiveBuffer, now: Double) throws {
            let received = relay.receive(data, from: hop, now: now)
            let result = try #require(received)
            guard case .audio(let packet) = result.body else { Issue.record("Missing audio"); return }
            queue.enqueue(.init(received: .init(peerID: result.peer.id, packet: packet)), receivedAt: now)
            #expect(relay.receive(data, from: hop, now: now) == nil)
            #expect(queue.queuedPacketCount <= 2)
        }
        for frame in 0..<30_000 {
            let now = Double(frame) * 0.02
            if frame % 100 == 0 {
                _ = b.receive(try a.make(.presence, now: now), from: peerA, now: now)
                _ = a.receive(try b.make(.presence, now: now), from: peerB, now: now)
            }
            let packet = RTCAudioPacket(sequenceNumber: UInt64(frame), codec: .pcm16, payload: Data([UInt8(frame % 251)]))
            try receive(a.make(.audio(packet), now: now), hop: peerA, relay: &b, queue: &queueB, now: now)
            try receive(b.make(.audio(packet), now: now), hop: peerB, relay: &a, queue: &queueA, now: now)
            let framesA = queueA.drain(now: now).readyPackets, framesB = queueB.drain(now: now).readyPackets
            for received in framesA { #expect(received.packet.payload == Data([UInt8(deliveredA % 251)])); deliveredA += 1 }
            for received in framesB { #expect(received.packet.payload == Data([UInt8(deliveredB % 251)])); deliveredB += 1 }
        }
        deliveredA += queueA.drain(now: 600).readyPackets.count
        deliveredB += queueB.drain(now: 600).readyPackets.count
        #expect(deliveredA == 30_000 && deliveredB == 30_000)
        queueA.reset(); queueB.reset()
        #expect(queueA.queuedPacketCount == 0 && queueB.queuedPacketCount == 0)
    }
}
