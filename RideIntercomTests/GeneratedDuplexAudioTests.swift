import AudioCore
import Codec
import Foundation
import Testing
@testable import RTC
@testable import RideIntercom

/// Synthetic time exercises the current codec, encrypted relay and playout path.
/// Discovery, radio transport and acoustic quality still require physical devices.
@Test @MainActor func tenMinutesOfGeneratedPCMThroughEncryptedDuplexTransport() throws {
    let format = AudioFormat(sampleRate: 16_000, channelCount: 1)
    let credential = RTCCredential.derived(groupID: "generated-audio", secret: "test-only-secret")
    let peers = [PeerID(rawValue: "a"), PeerID(rawValue: "b")]
    var relays = peers.map { peer in
        GroupRelay(request: CallStartRequest(
            sessionID: "generated-audio",
            localPeer: PeerDescriptor(id: peer, displayName: peer.rawValue),
            credential: credential,
            audioPolicy: RTCAudioPolicy(preferredSendFormat: RTCAudioFormat(audioFormat: format), preferredCodecs: [.pcm16])
        ))
    }
    var buffers = [PacketAudioReceiveBuffer(), PacketAudioReceiveBuffer()]
    let waves: [[Float]] = [1.0, 2.0].map { cycles in
        (0..<320).map { Float(sin(Double($0) * cycles * 2 * .pi / 320)) * 0.3 }
    }
    var decodedSamples = [0, 0], frameCounts = [0, 0], duplicateCounts = [0, 0]
    var maximumError: Float = 0
    func consume(_ report: PacketAudioReceiveBufferReport, receiver: Int) throws {
        #expect(report.queuedPacketCount <= 2)
        for received in report.readyPackets {
            #expect(received.peerID == peers[1 - receiver])
            #expect(received.packet.sequenceNumber == UInt64(frameCounts[receiver]))
            #expect(received.packet.capturedAt == Double(frameCounts[receiver]) * 0.02)
            frameCounts[receiver] += 1
            let decoded = try AppAudioCodecBridge.decode(received.packet)
            #expect(decoded.format == format)
            #expect(decoded.samples.count == 320)
            decodedSamples[receiver] += decoded.samples.count
            for (actual, expected) in zip(decoded.samples, waves[1 - receiver]) {
                maximumError = max(maximumError, abs(actual - expected))
            }
        }
    }
    for sequence in 0..<30_000 {
        let time = Double(sequence) * 0.02
        for sender in 0..<2 {
            let receiver = 1 - sender
            if sequence % 100 == 0 {
                let presence = try relays[sender].make(.presence, now: time)
                #expect(relays[receiver].receive(presence, from: peers[sender], now: time) != nil)
            }
            let packet = RTCAudioPacket(sequenceNumber: UInt64(sequence), codec: .pcm16,
                format: RTCAudioFormat(audioFormat: format), capturedAt: time,
                sampleCount: 320, payload: PCM16Codec.encode(waves[sender]))
            let payload = try relays[sender].make(.audio(packet), now: time)
            let reception = relays[receiver].receive(payload, from: peers[sender], now: time)
            let result = try #require(reception)
            guard case .audio(let receivedPacket) = result.body else {
                Issue.record("Expected common encrypted audio envelope"); return
            }
            buffers[receiver].enqueue(.init(received: .init(peerID: result.peer.id, packet: receivedPacket)), receivedAt: time)
            if relays[receiver].receive(payload, from: peers[sender], now: time) == nil { duplicateCounts[receiver] += 1 }
            try consume(buffers[receiver].drain(now: time), receiver: receiver)
        }
    }
    for receiver in 0..<2 {
        try consume(buffers[receiver].drain(now: 600), receiver: receiver)
        #expect(frameCounts[receiver] == 30_000)
        #expect(decodedSamples[receiver] == 9_600_000)
        #expect(duplicateCounts[receiver] == 30_000)
        #expect(buffers[receiver].queuedPacketCount == 0)
        buffers[receiver].reset()
        #expect(buffers[receiver].drain(now: 601).readyPackets.isEmpty)
    }
    #expect(maximumError < 0.000_04)
}
