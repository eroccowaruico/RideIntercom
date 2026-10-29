import AudioCore
import Foundation

/// Carry resampling phase across arbitrary device quanta. Rounding each input
/// buffer independently changes the clock; clamping every buffer's final sample
/// also introduces a small repeated plateau at each boundary.
final class MixerPCMStreamNormalizer {
    private var sourceFormat: AudioFormat?
    private var targetFormat: AudioFormat?
    private var inputEnd: Double?
    private var epoch = 0.0
    private var inputFrames = 0
    private var outputFrames = 0
    private var previous: [Float] = []

    func normalize(_ frame: PCMFrame, to target: AudioFormat, operation: AudioProcessingOperation)
        throws -> (frame: PCMFrame, report: AudioProcessingReport) {
        _ = try frame.validated()
        guard target.isValid else { throw AudioMixerError.formatCreationFailed(target) }
        if frame.format == target { return try MixerPCMNormalizer.normalize(frame, to: target, operation: operation) }
        if sourceFormat != frame.format || targetFormat != target
            || inputEnd.map({ abs(frame.capturedAt - $0) > 2 / frame.format.sampleRate }) == true {
            sourceFormat = frame.format; targetFormat = target
            inputFrames = 0; outputFrames = 0; previous = []; epoch = frame.capturedAt
        }
        let channels = target.channelCount
        let samples = MixerPCMNormalizer.convertChannels(frame.samples,
            sourceChannelCount: frame.format.channelCount, targetChannelCount: channels)
        let beginning = outputFrames
        let available = inputFrames + frame.frameCount
        let step = frame.format.sampleRate / target.sampleRate
        var converted: [Float] = []
        converted.reserveCapacity(Int(ceil(Double(frame.frameCount) / step)) * channels)
        while true {
            let position = Double(outputFrames) * step
            let lower = Int(floor(position + 1e-9))
            let fraction = max(0, position - Double(lower))
            let upper = fraction < 1e-9 ? lower : lower + 1
            guard upper < available, lower >= inputFrames - 1 else { break }
            for channel in 0..<channels {
                func sample(_ index: Int) -> Float {
                    index < inputFrames ? previous[channel] : samples[(index-inputFrames)*channels+channel]
                }
                converted.append(Float(Double(sample(lower)) * (1-fraction) + Double(sample(upper)) * fraction))
            }
            outputFrames += 1
        }
        if frame.frameCount > 0 { previous = Array(samples.suffix(channels)) }
        inputFrames = available
        inputEnd = frame.capturedAt + Double(frame.frameCount) / frame.format.sampleRate
        return (.init(sequenceNumber: frame.sequenceNumber, format: target,
            capturedAt: epoch + Double(beginning) / target.sampleRate, samples: converted),
            .init(operation: operation, sourceFormat: frame.format, targetFormat: target,
                inputSampleCount: frame.samples.count, outputSampleCount: converted.count, result: .applied))
    }
}
