import AudioCore
import Foundation
import Testing
@testable import Codec

@Test(arguments: [(CodecIdentifier.pcm16, 48000.0, 32000), (.opus, 48000, 32000),
    (.opus, 24000, 16000), (.opus, 16000, 24000), (.mpeg4AACELD, 48000, 32000),
    (.mpeg4AACELD, 48000, 64000), (.mpeg4AACELD, 24000, 32000), (.mpeg4AACELD, 16000, 32000)])
func conversationKeepsBriefRepliesAndOneToThreeSecondPauses(setting: (CodecIdentifier, Double, Int)) throws {
    let (codec, rate, bitRate) = setting
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: codec, format: format,
        aacELDv2Options: .init(bitRate: bitRate), opusOptions: .init(bitRate: bitRate)))
    let decoder = StreamingCodecDecoder()
    // Short 100 ms acknowledgements separated by 1, 2 and 3 seconds of silence.
    let starts = [0.1, 1.2, 3.3, 6.4]
    let length = Int(rate * 7)
    var signal = Array(repeating: Float(0), count: length)
    for (utterance, start) in starts.enumerated() {
        for sample in 0..<Int(rate * 0.1) {
            let time = Double(sample) / rate
            let envelope = min(1, min(time / 0.005, (0.1 - time) / 0.005))
            signal[Int(start * rate) + sample] = Float(envelope * 0.3 * sin(time * 2 * .pi * Double(300 + utterance * 110)))
        }
    }
    let count = Int(rate * 0.02)
    var output: [Float] = []
    var end: Double?
    for offset in stride(from: 0, to: length, by: count) {
        let input = PCMFrame(sequenceNumber: UInt64(offset / count), format: format,
            capturedAt: Double(offset) / rate, samples: Array(signal[offset..<(offset + count)]))
        guard let packet = try encoder.encode(input) else { continue }
        let decoded = try decoder.decode(packet)
        if let end {
            #expect(abs(decoded.capturedAt - end) < 1 / rate,
                "Every decoded boundary must preserve time without missing or overlapping samples")
        }
        end = decoded.capturedAt + Double(decoded.frameCount) / rate
        output += decoded.samples
    }
    #expect(output.count > length - Int(rate * 0.04))
    for start in starts {
        let beginning = Int(start * rate)
        let region = output[beginning..<Int((start + 0.14) * rate)]
        let audible = region.filter { abs($0) > 0.02 }.count
        #expect(audible > Int(rate * 0.07), "A 100 ms acknowledgement must survive in full")
        // No prior utterance may repeat in the middle of the following pause.
        let silence = output[Int((start + 0.25) * rate)..<Int((start + 0.4) * rate)]
        #expect(silence.allSatisfy { abs($0) < 0.001 })
    }
}
