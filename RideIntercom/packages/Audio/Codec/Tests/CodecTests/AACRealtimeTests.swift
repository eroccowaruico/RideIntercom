import AudioCore
import Foundation
import Testing

@Test(arguments: [CodecIdentifier.opus, .mpeg4AACELD])
func realtimeCodecEmitsFirstTenMillisecondsWithoutWaitingForTwenty(codec: CodecIdentifier) throws {
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: codec, format: .init()))
    let packet = try #require(try encoder.encode(.init(sequenceNumber: 0, capturedAt: 0,
        samples: (0..<480).map { Float(sin(Double($0) * 0.04) * 0.2) })))
    #expect(packet.sampleCount == 480)
}

@Test func aacBitrateChoicesComeFromTheNativeEncoder() {
    let rates = CodecSupport.availableEncodingBitRates(codec: .mpeg4AACELD, format: .init())
    #expect(rates.contains(32_000))
    #expect(rates.contains(64_000))
    #expect(!rates.contains(12_000))
    #expect(rates == Array(Set(rates)).sorted())
}
@testable import Codec

@Test(arguments: [(16000.0, 24000), (16000.0, 32000), (24000.0, 24000), (24000.0, 32000), (24000.0, 64000), (48000.0, 32000), (48000.0, 64000), (48000.0, 128000)])
func aacELDActuallyEncodesMonoWithoutPCMFallback(setting: (Double, Int)) throws {
    let (rate, bitRate) = setting
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let configuration = CodecEncodingConfiguration(codec: .mpeg4AACELD, format: format,
        aacELDv2Options: .init(bitRate: bitRate))
    let report = CodecRuntimeReport.resolving(configuration)
    #expect(report.selectedCodec == .mpeg4AACELD)
    #expect(!report.isFallback)
    let encoder = CodecEncoder(configuration: configuration)
    let decoder = CodecDecoder()
    for index in 0..<6 {
        let silent = index == 3
        let samples = (0..<Int(rate * 0.02)).map { sample in
            silent ? Float(0) : Float(sin(Double(sample) * 2 * .pi * 440 / rate) * 0.3)
        }
        let frame = PCMFrame(sequenceNumber: UInt64(index), format: format, capturedAt: Double(index) * 0.02, samples: samples)
        let encoded = try encoder.encode(frame)
        #expect(encoded.codec == .mpeg4AACELD)
        #expect(encoded.bitRate == bitRate)
        let output = try decoder.decode(encoded)
        #expect(output.format == format)
        #expect(output.samples.count == samples.count)
        #expect(output.capturedAt == frame.capturedAt)
        if silent { #expect(output.samples.allSatisfy { abs($0) < 0.0001 }) }
        else { #expect(output.samples.contains { abs($0) > 0.1 }) }
    }
}

@Test(arguments: [CodecIdentifier.pcm16, .opus, .mpeg4AACELD])
func continuousToneHasNoPacketBoundaryClicks(codec: CodecIdentifier) throws {
    let configuration = CodecEncodingConfiguration(codec: codec, aacELDv2Options: .init(bitRate: 32000))
    let encoder = try StreamingCodecEncoder(configuration: configuration)
    let decoder = StreamingCodecDecoder()
    var rendered: [Float] = []
    var boundaries: [Int] = []
    for block in 0..<50 {
        let samples = (0..<960).map { Float(sin(Double(block * 960 + $0) * 2 * .pi * 440 / 48000) * 0.3) }
        let frame = PCMFrame(sequenceNumber: UInt64(block), capturedAt: Double(block) * 0.02, samples: samples)
        if let packet = try encoder.encode(frame) { boundaries.append(rendered.count); rendered += try decoder.decode(packet).samples }
    }
    let jumps = boundaries.filter { $0 > 0 && $0 < rendered.count }.map { abs(rendered[$0] - rendered[$0 - 1]) }
    #expect(rendered.count >= 47000, "The full second must arrive apart from the final native codec packet")
    #expect(jumps.max() ?? 1 < 0.04, "A 440 Hz sine at 0.3 amplitude has steps below 0.018; a packet seam must not create a click")
}
