import AudioCore
import AVFAudio
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
    private var converter: AVAudioConverter?

    func normalize(_ frame: PCMFrame, to target: AudioFormat, operation: AudioProcessingOperation)
        throws -> (frame: PCMFrame, report: AudioProcessingReport) {
        _ = try frame.validated()
        guard target.isValid else { throw AudioMixerError.formatCreationFailed(target) }
        if frame.format == target || frame.samples.isEmpty {
            return try MixerPCMNormalizer.normalize(frame, to: target, operation: operation)
        }
        if sourceFormat != frame.format || targetFormat != target
            || inputEnd.map({ abs(frame.capturedAt - $0) > 2 / frame.format.sampleRate }) == true {
            if sourceFormat != frame.format || targetFormat != target {
                var replacement: AVAudioConverter?
                let ratio = max(frame.format.sampleRate, target.sampleRate) / min(frame.format.sampleRate, target.sampleRate)
                if abs(ratio - ratio.rounded()) > 1e-9 {
                    guard let input = AVAudioFormat(standardFormatWithSampleRate: frame.format.sampleRate, channels: AVAudioChannelCount(target.channelCount)),
                          let output = AVAudioFormat(standardFormatWithSampleRate: target.sampleRate, channels: AVAudioChannelCount(target.channelCount)),
                          let native = AVAudioConverter(from: input, to: output) else {
                        throw AudioMixerError.formatCreationFailed(target)
                    }
                    // Native filtering removes fractional-rate images
                    // without waiting for future capture blocks or a prime buffer.
                    native.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
                    native.sampleRateConverterQuality = AVAudioQuality.high.rawValue
                    native.primeMethod = .none
                    replacement = native
                }
                converter = replacement
            } else { converter?.reset() }
            sourceFormat = frame.format; targetFormat = target
            inputFrames = 0; outputFrames = 0; previous = []; epoch = frame.capturedAt
        }
        let channels = target.channelCount
        let samples = MixerPCMNormalizer.convertChannels(frame.samples,
            sourceChannelCount: frame.format.channelCount, targetChannelCount: channels)
        if let converter {
            return try convertNative(frame, samples: samples, target: target, operation: operation, converter: converter)
        }
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

    private func convertNative(_ frame: PCMFrame, samples: [Float], target: AudioFormat,
                               operation: AudioProcessingOperation, converter: AVAudioConverter) throws
        -> (frame: PCMFrame, report: AudioProcessingReport) {
        let input = try PCMFrame(sequenceNumber: frame.sequenceNumber,
            format: .init(sampleRate: frame.format.sampleRate, channelCount: target.channelCount),
            capturedAt: frame.capturedAt, samples: samples).makePCMBuffer()
        let required = ceil(Double(frame.frameCount) * target.sampleRate / frame.format.sampleRate) + 64
        guard required.isFinite, required < Double(UInt32.max) else { throw AudioMixerError.formatCreationFailed(target) }
        let capacity = AVAudioFrameCount(required)
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw AudioMixerError.formatCreationFailed(target)
        }
        var offset: AVAudioFrameCount = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { requested, state in
            guard offset < input.frameLength, requested > 0 else { state.pointee = .noDataNow; return nil }
            let count = min(requested, input.frameLength - offset)
            guard let part = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count) else {
                state.pointee = .noDataNow; return nil
            }
            part.frameLength = count
            for channel in 0..<target.channelCount {
                part.floatChannelData![channel].update(from: input.floatChannelData![channel].advanced(by: Int(offset)), count: Int(count))
            }
            offset += count
            state.pointee = .haveData
            return part
        }
        guard status != .error, offset == input.frameLength,
              let result = PCMFrame(buffer: output, sequenceNumber: frame.sequenceNumber,
                capturedAt: epoch + Double(outputFrames) / target.sampleRate) else {
            throw AudioProcessingFailure(operation: operation, sourceFormat: frame.format,
                targetFormat: target, reason: "Native fractional conversion did not consume the complete frame")
        }
        outputFrames += result.frameCount
        inputEnd = frame.capturedAt + Double(frame.frameCount) / frame.format.sampleRate
        return (result, .init(operation: operation, sourceFormat: frame.format, targetFormat: target,
            inputSampleCount: frame.samples.count, outputSampleCount: result.samples.count, result: .applied))
    }

}
