import AudioCore
import AVFAudio
import Foundation
import Testing
@testable import Codec

@Test(arguments: [(8_000, 24_000), (12_000, 24_000), (16_000, 24_000), (24_000, 24_000),
                  (32_000, 32_000), (48_000, 48_000), (128_000, 128_000), (256_000, 128_000)])
func opusManualLowBandwidthOptionsKeepOneNormalizationContract(input: (Int, Int)) throws {
    let (requested, expected) = input
    #expect(OpusOptions().bitRate == 48_000)
    #expect(OpusOptions.allowedBitRateRange == 24_000...128_000)
    #expect(OpusOptions(bitRate: requested).bitRate == expected)
    let decoded = try JSONDecoder().decode(OpusOptions.self, from: Data("{\"bitRate\":\(requested)}".utf8))
    #expect(decoded.bitRate == expected)
    var changed = OpusOptions(); changed.bitRate = requested
    #expect(changed.bitRate == expected)
    #expect(try JSONDecoder().decode(OpusOptions.self, from: JSONEncoder().encode(changed)) == changed)
}

@Test(arguments: [24_000, 32_000], [16_000.0, 24_000, 48_000])
func opusManualLowBandwidthAppliesNativeRateAndKeepsBriefReplies(bitRate: Int, sampleRate: Double) throws {
    let format = AudioFormat(sampleRate: sampleRate, channelCount: 1)
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: .opus, format: format,
        opusOptions: .init(bitRate: bitRate)))
    // Read the native instance actually used for conversion, not configuration
    // metadata or a separately constructed AVAudioConverter. Test-only access.
    let native = try #require(Mirror(reflecting: encoder).children.first { $0.label == "converter" }?.value as? AVAudioConverter)
    #expect(native.bitRate == bitRate)
    #expect(native.inputFormat.sampleRate == sampleRate && native.outputFormat.sampleRate == sampleRate)
    #expect(native.outputFormat.streamDescription.pointee.mFramesPerPacket == UInt32(sampleRate / 200))
    let samples = (0..<Int(sampleRate / 100)).map { Float(sin(Double($0) * 2 * .pi * 440 / sampleRate) * 0.2) }
    let packet = try #require(try encoder.encode(.init(sequenceNumber: 0, format: format, capturedAt: 0, samples: samples)))
    let decoded = try StreamingCodecDecoder().decode(packet)
    #expect(!decoded.samples.isEmpty && decoded.samples.allSatisfy(\.isFinite))
    #expect(native.bitRate == bitRate)
    // Reuse the existing timing, 100ms-signal and silence-contamination assertions
    // unchanged. This is not the default 48kbps waveform-fidelity gate.
    try conversationKeepsBriefRepliesAndOneToThreeSecondPauses(setting: (.opus, sampleRate, bitRate))
}

@Test(arguments: [16_000.0, 24_000, 48_000])
func opusManualLowBandwidthReducesEncodedPayload(sampleRate: Double) throws {
    let format = AudioFormat(sampleRate: sampleRate, channelCount: 1)
    var totals: [Int: Int] = [:]
    for bitRate in [24_000, 32_000, 48_000] {
        let encoder = try StreamingCodecEncoder(configuration: .init(codec: .opus, format: format,
            opusOptions: .init(bitRate: bitRate)))
        let quantum = Int(sampleRate / 100)
        var total = 0
        for index in 0..<100 {
            let samples = (0..<quantum).map { sample in
                let time = Double(index * quantum + sample) / sampleRate
                return Float(0.3 * sin(time * 2 * .pi * 440) + 0.2 * sin(time * 2 * .pi * 1730))
            }
            if let packet = try encoder.encode(.init(sequenceNumber: UInt64(index), format: format,
                capturedAt: Double(index) / 100, samples: samples)) {
                total += try CompressedPayloadEnvelope.decode(packet.payload, expectedCodec: .opus).data.count
            }
        }
        totals[bitRate] = total
    }
    #expect(try #require(totals[24_000]) < #require(totals[32_000]))
    #expect(try #require(totals[32_000]) < #require(totals[48_000]))
}
