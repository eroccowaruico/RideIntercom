import AudioCore
import Foundation
import Testing
@testable import Codec

@Test(arguments: [CodecIdentifier.mpeg4AACELD, .mpeg4AACELDv2, .opus], [16_000.0, 24_000.0, 48_000.0])
func finiteAACStreamPreservesAllFiveSecondsIncludingTheFinalChunk(codec: CodecIdentifier, rate: Double) throws {
    let format = AudioFormat(sampleRate: rate, channelCount: codec == .mpeg4AACELDv2 ? 2 : 1)
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: codec, format: format, aacELDv2Options: .init(bitRate: codec == .mpeg4AACELDv2 ? 64_000 : 32_000)))
    let decoder = StreamingCodecDecoder()
    let total = Int(rate * 5)
    var rendered: [Float] = []
    var decodedFrames = 0
    var decodedEnd = 0.0
    var packets = 0
    for beginning in stride(from: 0, to: total, by: 128) {
        let count = min(128, total - beginning)
        let samples = (0..<(count * format.channelCount)).map { sample in
            let index = beginning + sample / format.channelCount
            return Float(0.2 * sin(Double(index) * 2 * .pi * (index < total - 2400 ? 440 : 997) / format.sampleRate))
        }
        if let packet = try encoder.encode(.init(sequenceNumber: UInt64(beginning / 128), format: format,
                                                capturedAt: Double(beginning) / format.sampleRate, samples: samples)) {
            let frame = try decoder.decode(packet)
            rendered += frame.samples
            decodedFrames += frame.frameCount
            decodedEnd = frame.capturedAt + Double(frame.frameCount) / format.sampleRate
            packets += 1
        }
    }
    for packet in try encoder.finish() {
        let frame = try decoder.decode(packet)
        rendered += frame.samples
        decodedFrames += frame.frameCount
        decodedEnd = frame.capturedAt + Double(frame.frameCount) / format.sampleRate
        packets += 1
    }
    #expect(try encoder.finish().isEmpty)
    print("finite codec=\(codec) rate=\(rate) inputFrames=\(total) decodedFrames=\(decodedFrames) decodedEnd=\(decodedEnd) packets=\(packets)")
    #expect(decodedFrames == total, "A finite recording must not leave its final native packet inside the stream encoder")
    #expect(abs(decodedEnd - 5) <= 1 / format.sampleRate)
    // The final 100 ms is a 997 Hz tone: count alone cannot detect silence.
    let tail = Array(rendered.suffix(Int(rate * 0.1) * format.channelCount))
    let mono = stride(from: 0, to: tail.count, by: format.channelCount).map { Double(tail[$0]) }
    let energy = mono.reduce(0) { $0 + $1 * $1 } / Double(max(1, mono.count))
    #expect(energy > 0.001)
    let projection = mono.enumerated().reduce((0.0, 0.0)) { sum, item in
        let phase = 2 * Double.pi * 997 * Double(item.offset) / rate
        return (sum.0 + item.element * cos(phase), sum.1 + item.element * sin(phase))
    }
    #expect(hypot(projection.0, projection.1) / Double(max(1, mono.count)) > 0.03)
}

@Test func finishedStreamCanStartAgain() throws {
    let format = AudioFormat(sampleRate: 16_000, channelCount: 1)
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD, format: format))
    let decoder = StreamingCodecDecoder()
    for cycle in 0..<2 {
        let input = PCMFrame(sequenceNumber: UInt64(cycle), format: format, capturedAt: Double(cycle),
                             samples: (0..<320).map { Float(0.2 * sin(Double($0) * 0.2)) })
        var output = 0
        if let packet = try encoder.encode(input) { output += try decoder.decode(packet).frameCount }
        for packet in try encoder.finish() { output += try decoder.decode(packet).frameCount }
        #expect(output == input.frameCount)
        #expect(try encoder.finish().isEmpty)
    }
}

@Test func streamingDecoderRejectsInvalidValidSampleCounts() throws {
    let format = AudioFormat(sampleRate: 48_000, channelCount: 2)
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: .opus, format: format))
    let packet = try #require(try encoder.encode(.init(sequenceNumber: 1, format: format,
        capturedAt: 0, samples: Array(repeating: 0.2, count: 960 * 2))))
    for count in [-1, 1, packet.sampleCount + 2] {
        var invalid = packet
        invalid.sampleCount = count
        #expect(throws: CodecError.malformedPayload(.opus)) { try StreamingCodecDecoder().decode(invalid) }
    }
}
