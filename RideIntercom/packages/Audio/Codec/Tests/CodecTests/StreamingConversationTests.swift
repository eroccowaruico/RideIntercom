import AudioCore
import Foundation
import Testing
@testable import Codec

@Test(arguments: [(CodecIdentifier.pcm16, 48000.0), (.opus, 48000), (.opus, 24000), (.opus, 16000),
    (.mpeg4AACELD, 48000), (.mpeg4AACELD, 24000), (.mpeg4AACELD, 16000)])
func silenceSuspensionPreservesQuietRepliesAndStopsSending(setting: (CodecIdentifier, Double)) throws {
    let (codec, rate) = setting
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let configuration = CodecEncodingConfiguration(codec: codec, format: format,
        aacELDv2Options: .init(bitRate: 48000), opusOptions: .init(bitRate: 32000))
    let encoder = try StreamingCodecEncoder(configuration: configuration, suppressesSilence: true)
    let continuous = try StreamingCodecEncoder(configuration: configuration)
    let decoder = StreamingCodecDecoder()
    let starts = [0.1, 1.2, 3.3, 6.4]
    var output = Array(repeating: Float(0), count: Int(rate * 7))
    var input = output
    for (utterance, start) in starts.enumerated() {
        for sample in 0..<Int(rate * 0.1) {
            let t = Double(sample) / rate
            let fade = min(1, min(t / 0.005, (0.1 - t) / 0.005))
            input[Int(start * rate) + sample] = Float(fade * 0.03 * sin(t * 2 * .pi * Double(300 + 110 * utterance)))
        }
    }
    var bytes = 0, continuousBytes = 0, packets = 0
    let count = Int(rate * 0.01)
    for offset in stride(from: 0, to: input.count, by: count) {
        let frame = PCMFrame(sequenceNumber: UInt64(offset / count), format: format,
            capturedAt: Double(offset) / rate, samples: Array(input[offset..<offset + count]))
        continuousBytes += try continuous.encode(frame)?.payload.count ?? 0
        guard let packet = try encoder.encode(frame) else { continue }
        bytes += packet.payload.count; packets += 1
        #expect(!((0.5..<1.2).contains(frame.capturedAt) || (1.6..<3.3).contains(frame.capturedAt)
            || (3.7..<6.4).contains(frame.capturedAt)), "Sustained digital silence must not invoke transmission")
        let decoded = try decoder.decode(packet)
        let first = Int((decoded.capturedAt * rate).rounded())
        for (index, value) in decoded.samples.enumerated() where first + index < output.count {
            output[first + index] = value
        }
    }
    #expect(bytes < continuousBytes / 4, "Seven seconds with four brief replies should save over 75% of payload bytes")
    #expect(packets < 140)
    for (utterance, start) in starts.enumerated() {
        // Native codecs have their own priming delay, bounded to 30 ms at 16 kHz AAC.
        // Compare the complete quiet acknowledgement, not just its loudest peak.
        let first = Int(start * rate), length = Int(0.1 * rate)
        var best = 0.0
        for shift in 0...Int(rate * 0.03) {
            var dot = 0.0, a = 0.0, b = 0.0
            for i in 0..<length {
                let x = Double(input[first + i]), y = Double(output[first + shift + i])
                dot += x * y; a += x * x; b += y * y
            }
            best = max(best, dot / max(1e-20, sqrt(a * b)))
        }
        #expect(best > 0.95, "Quiet reply \(utterance) lost identity after suspension: \(best)")
        #expect(output[Int((start + 0.25) * rate)..<Int((start + 0.4) * rate)].allSatisfy { abs($0) < 0.001 })
    }
    print("silence budget \(codec) \(rate): \(bytes)/\(continuousBytes) bytes, \(packets) packets")
}

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
