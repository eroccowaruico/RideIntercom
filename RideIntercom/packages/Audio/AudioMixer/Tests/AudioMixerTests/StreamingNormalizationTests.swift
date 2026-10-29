import AudioCore
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
    #expect(output.enumerated().allSatisfy { index, value in
        abs(value - Float(0.2 * sin(Double(index) * 2 * .pi * 400 / rates.1))) < 0.0002
    })
}
