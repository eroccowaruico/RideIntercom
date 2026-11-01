import AudioCore
import Codec
import Foundation
import RTC

/// One bounded recording of the actual transmitted packets. Capture and codec
/// callbacks share this lock; the UI only takes the completed PCM timeline.
nonisolated final class AudioCheckRecording: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder = StreamingCodecDecoder()
    private let format: AudioFormat
    private var samples: [Float]
    private var inputFormat: AudioFormat?
    private var inputFrames = 0
    private var origin: TimeInterval?
    private var latency: TimeInterval = 0
    private var failure: (any Error)?

    init(format: AudioFormat) {
        self.format = format
        samples = Array(repeating: 0, count: Int(format.sampleRate * 5) * format.channelCount)
    }

    func setProcessingLatency(_ value: TimeInterval) {
        lock.withLock {
            if value.isFinite && value >= 0 { latency = value }
            else { failure = AppAudioPipelineError.invalidFormat }
        }
    }

    func acceptInput(_ frame: PCMFrame) -> PCMFrame? {
        lock.withLock {
            guard frame.format.isValid, frame.frameCount > 0, frame.capturedAt.isFinite,
                  frame.samples.count.isMultiple(of: frame.format.channelCount) else { return nil }
            if let inputFormat, inputFormat != frame.format { failure = AppAudioPipelineError.invalidFormat; return nil }
            if inputFormat == nil { inputFormat = frame.format; origin = frame.capturedAt }
            let count = min(frame.frameCount, max(0, Int(frame.format.sampleRate * 5) - inputFrames))
            guard count > 0 else { return nil }
            inputFrames += count
            var accepted = frame
            accepted.samples = Array(frame.samples.prefix(count * frame.format.channelCount))
            return accepted
        }
    }

    func receive(_ packet: RTCAudioPacket) {
        lock.withLock {
            do {
                let frame = try AppAudioCodecBridge.decode(packet, using: decoder)
                guard frame.format == format, let origin else { throw AppAudioPipelineError.invalidFormat }
                let beginning = Int(((frame.capturedAt - origin - latency) * format.sampleRate).rounded())
                let lower = max(0, beginning), upper = min(samples.count / format.channelCount, beginning + frame.frameCount)
                guard lower < upper else { return }
                let source = (lower - beginning) * format.channelCount
                samples.replaceSubrange((lower * format.channelCount)..<(upper * format.channelCount),
                    with: frame.samples[source..<(source + (upper - lower) * format.channelCount)])
            } catch { failure = error }
        }
    }

    func recordedFrames() throws -> [PCMFrame] {
        try lock.withLock {
            if let failure { throw failure }
            guard let inputFormat, let origin else { return [] }
            let count = min(samples.count / format.channelCount,
                Int((Double(inputFrames) / inputFormat.sampleRate * format.sampleRate).rounded()))
            return stride(from: 0, to: count, by: 1024).map { offset in
                let end = min(count, offset + 1024)
                return PCMFrame(sequenceNumber: UInt64(offset / 1024), format: format,
                    capturedAt: origin + Double(offset) / format.sampleRate,
                    samples: Array(samples[(offset * format.channelCount)..<(end * format.channelCount)]))
            }
        }
    }
}
