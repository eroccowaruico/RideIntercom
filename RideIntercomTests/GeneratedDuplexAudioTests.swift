import AudioCore
import Codec
import Foundation
import Testing
@testable import RTC
@testable import RideIntercom

/// Synthetic time exercises real PCM codec, authenticated payload, jitter and replay paths.
/// Discovery, radio transport and acoustic quality still require physical devices.
@Test @MainActor func tenMinutesOfGeneratedPCMThroughEncryptedDuplexTransport() throws {
    let format = AudioFormat(sampleRate: 16_000, channelCount: 1)
    let credential = RTCCredential.derived(groupID: "generated-audio", secret: "test-only-secret")
    let peers = [PeerID(rawValue: "a"), PeerID(rawValue: "b")]
    let sessions = try peers.map { peer in
        try MultipeerPacketMediaSession(request: CallStartRequest(
            sessionID: "generated-audio",
            localPeer: PeerDescriptor(id: peer, displayName: peer.rawValue),
            credential: credential,
            audioPolicy: RTCAudioPolicy(preferredSendFormat: RTCAudioFormat(audioFormat: format), preferredCodecs: [.pcm16])
        ))
    }
    sessions.forEach { $0.isActive = true }
    let waves: [[Float]] = [1.0, 2.0].map { cycles in
        (0..<320).map { Float(sin(Double($0) * cycles * 2 * .pi / 320)) * 0.3 }
    }
    var decodedSamples = [0, 0]
    var expectedSequences: [UInt64] = [0, 0]
    var maximumError: Float = 0
    func consume(_ report: PacketAudioReceiveBufferReport?, receiver: Int) throws {
        guard let report else { Issue.record("Active media returned no report"); return }
        #expect(report.queuedPacketCount <= 2)
        for received in report.readyPackets {
            #expect(received.peerID == peers[1 - receiver])
            #expect(received.packet.sequenceNumber == expectedSequences[receiver])
            expectedSequences[receiver] += 1
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
            let packet = RTCAudioPacket(sequenceNumber: UInt64(sequence), codec: .pcm16,
                format: RTCAudioFormat(audioFormat: format), capturedAt: time,
                sampleCount: 320, payload: PCM16Codec.encode(waves[sender]))
            let payload = try #require(try sessions[sender].makePayload(from: packet))
            guard case .packetAudio(let envelope) = try MultipeerPayloadBuilder.decode(payload.data, credential: credential) else {
                Issue.record("Expected encrypted packet audio"); return
            }
            let receiver = 1 - sender
            try consume(sessions[receiver].accept(envelope, from: peers[sender], receivedAt: time), receiver: receiver)
            try consume(sessions[receiver].accept(envelope, from: peers[sender], receivedAt: time), receiver: receiver)
        }
    }
    for receiver in 0..<2 {
        try consume(sessions[receiver].drain(now: 600), receiver: receiver)
        #expect(expectedSequences[receiver] == 30_000)
        #expect(decodedSamples[receiver] == 9_600_000)
        #expect(sessions[receiver].drain(now: 600)?.droppedPacketCount == 30_000)
        #expect(sessions[receiver].drain(now: 600)?.queuedPacketCount == 0)
        sessions[receiver].isActive = false
        #expect(sessions[receiver].timeUntilNextReadyPacket(now: 600) == nil)
    }
    #expect(maximumError < 0.000_04)
}
