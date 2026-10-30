import AudioCore
import AVFAudio
import Foundation
import Testing
@testable import AudioMixer

@Test(arguments: [(44100.0,48000.0),(48000.0,44100.0),(48000.0,96000.0),(48000.0,16000.0)])
func streamingNormalizationKeepsFractionalSampleClock(rates: (Double, Double)) throws {
    let converter = MixerPCMStreamNormalizer()
    var output: [Float] = []
    var end: Double?
    for offset in stride(from: 0, to: Int(rates.0), by: 256) {
        let count = min(256, Int(rates.0) - offset)
        let samples = (0..<count).map { Float(0.2 * sin(Double(offset + $0) * 2 * .pi * 400 / rates.0)) }
        let result = try converter.normalize(.init(sequenceNumber: UInt64(offset),
            format: .init(sampleRate: rates.0, channelCount: 1), capturedAt: Double(offset) / rates.0, samples: samples),
            to: .init(sampleRate: rates.1, channelCount: 1), operation: .normalizeSink).frame
        if let end { #expect(abs(result.capturedAt - end) < 0.1 / rates.1) }
        end = result.capturedAt + Double(result.frameCount) / rates.1
        output += result.samples
    }
    #expect(abs(output.count - Int(rates.1)) <= 1)
    if rates.0 == 44100 || rates.1 == 44100 {
        let input = (0..<Int(rates.0)).map { Float(0.2 * sin(Double($0) * 2 * .pi * 400 / rates.0)) }
        let reference = try nativeFractionalReference(input, from: rates.0, to: rates.1)
        #expect(output.count == reference.count)
        #expect(zip(output, reference).allSatisfy { abs($0 - $1) < 0.000001 },
            "Fragmenting capture must not alter one sample of the continuous native conversion")
    } else {
        #expect(output.enumerated().allSatisfy { index, value in
            abs(value - Float(0.2 * sin(Double(index) * 2 * .pi * 400 / rates.1))) < 0.0002
        })
    }
}


/// Independent whole-signal reference: a single native conversion, no package
/// normalizer, source scheduling, capture boundaries, or packet clocks.
func nativeFractionalReference(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
    let a = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1)!
    let b = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1)!
    let converter = AVAudioConverter(from: a, to: b)!
    converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    converter.primeMethod = .none
    let output = AVAudioPCMBuffer(pcmFormat: b, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * target / source) + 64))!
    var cursor = 0, error: NSError?
    let status = converter.convert(to: output, error: &error) { requested, state in
        guard cursor < samples.count else { state.pointee = .noDataNow; return nil }
        let count = min(Int(requested), samples.count - cursor)
        let part = AVAudioPCMBuffer(pcmFormat: a, frameCapacity: AVAudioFrameCount(count))!
        part.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { part.floatChannelData![0][i] = samples[cursor + i] }
        cursor += count; state.pointee = .haveData
        return part
    }
    #expect(status != .error)
    #expect(cursor == samples.count)
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

@Test(arguments: [(44100.0,48000.0),(48000.0,44100.0)])
func fractionalFilterRejectsImagesWithoutAnExtraCaptureBlock(rates: (Double, Double)) throws {
    let format = AudioFormat(sampleRate: rates.0, channelCount: 1)
    let target = AudioFormat(sampleRate: rates.1, channelCount: 1)
    let converter = MixerPCMStreamNormalizer()
    var output: [Float] = []
    for offset in stride(from: 0, to: Int(rates.0), by: 256) {
        let count = min(256, Int(rates.0) - offset)
        let frame = PCMFrame(sequenceNumber: UInt64(offset), format: format, capturedAt: Double(offset) / rates.0,
            samples: (0..<count).map { Float(0.2 * sin(Double(offset + $0) * 2 * .pi * 600 / rates.0)) })
        output += try converter.normalize(frame, to: target, operation: .normalizeSource).frame.samples
        #expect(abs(Double(output.count) - Double(offset + count) * rates.1 / rates.0) <= 1,
            "Every capture must produce its output without another block of lookahead")
    }
    let start = Int(rates.1 * 0.005)
    let samples = Array(output.dropFirst(start)).map(Double.init)
    let wave = samples.indices.map { (sin(Double($0 + start) * 2 * .pi * 600 / rates.1), cos(Double($0 + start) * 2 * .pi * 600 / rates.1)) }
    let sine = zip(samples,wave).reduce(0.0) { $0 + $1.0 * $1.1.0 } * 2 / Double(samples.count)
    let cosine = zip(samples,wave).reduce(0.0) { $0 + $1.0 * $1.1.1 } * 2 / Double(samples.count)
    #expect(abs(hypot(sine,cosine) - 0.2) < 0.0002)
    let error = samples.indices.map { abs(samples[$0] - wave[$0].0 * sine - wave[$0].1 * cosine) }.max() ?? 1
    #expect(error < 0.00002, "Fractional-rate images must not trigger lossy-codec noise bursts")
    let impulse = MixerPCMStreamNormalizer()
    let result = try impulse.normalize(.init(sequenceNumber: 0, format: format, capturedAt: 0,
        samples: (0..<441).map { $0 == 100 ? 1 : 0 }), to: target, operation: .normalizeSource).frame
    let peak = try #require(result.samples.indices.max { abs(result.samples[$0]) < abs(result.samples[$1]) })
    #expect(abs(Double(peak) / rates.1 - 100 / rates.0) < 0.001,
        "The native filter's propagation delay must stay below one millisecond")
}

@Test func fractionalStereoPreservesBothIndependentChannels() throws {
    let converter = MixerPCMStreamNormalizer()
    var output: [Float] = []
    let left = (0..<4410).map { Float(0.2 * sin(Double($0) * 2 * .pi * 400 / 44100)) }
    let right = (0..<4410).map { Float(0.1 * sin(Double($0) * 2 * .pi * 900 / 44100)) }
    for block in 0..<10 {
        let samples = (block * 441..<(block + 1) * 441).flatMap { [left[$0], right[$0]] }
        output += try converter.normalize(.init(sequenceNumber: UInt64(block),
            format: .init(sampleRate: 44100, channelCount: 2), capturedAt: Double(block) / 100, samples: samples),
            to: .init(sampleRate: 48000, channelCount: 2), operation: .normalizeSource).frame.samples
    }
    let expectedLeft = try nativeFractionalReference(left, from: 44100, to: 48000)
    let expectedRight = try nativeFractionalReference(right, from: 44100, to: 48000)
    #expect(output.count == expectedLeft.count * 2)
    #expect(expectedLeft.indices.allSatisfy { abs(output[$0 * 2] - expectedLeft[$0]) < 0.000001
        && abs(output[$0 * 2 + 1] - expectedRight[$0]) < 0.000001 })
}
