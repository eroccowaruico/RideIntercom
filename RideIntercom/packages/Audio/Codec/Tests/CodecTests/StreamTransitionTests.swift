import AudioCore
import Foundation
import Testing
@testable import Codec

@Test(arguments: [CodecIdentifier.opus, .mpeg4AACELD])
func codecStreamRestartHasNoAbruptSampleStep(codec: CodecIdentifier) throws {
    let decoder = StreamingCodecDecoder()
    var previous: Float?
    var totalFrames = 0
    for segment in 0..<2 {
        let encoder = try StreamingCodecEncoder(configuration: .init(codec: codec,
            aacELDv2Options: .init(bitRate: 64000)))
        for number in 0..<40 {
            let samples = (0..<480).map { Float(sin(Double(number * 480 + $0) * 2 * .pi * 410 / 48000 + Double(segment)) * 0.3) }
            let input = PCMFrame(sequenceNumber: UInt64(number), capturedAt: Double(segment) * 0.4 + Double(number) / 100, samples: samples)
            guard let packet = try encoder.encode(input) else { continue }
            let decoded = try decoder.decode(packet)
            if segment == 1, number == 0, let previous, let first = decoded.samples.first {
                #expect(abs(first - previous) < 0.00001, "A new stream must ramp from the preceding sample, not jump to silence")
            }
            previous = decoded.samples.last
            totalFrames += decoded.frameCount
        }
    }
    #expect(totalFrames >= 38000, "A transition must not buffer or omit a packet")
}
