import Foundation

/// An explicit discontinuity uses a 2 ms ramp to silence and a 2 ms ramp back.
/// No samples are queued, stretched or replayed. Normal streaming is bit exact.
/// Own this value on the same serial processing path as its PCM frames.
public struct PCMStreamTransition: Sendable {
    private var last: [Float] = []
    private var beginning: [Float] = []
    private var elapsed: TimeInterval = 0
    private var settling: TimeInterval = 0
    private var hasResumed = false
    private var holding = false
    public private(set) var isTransitioning = false

    public init() {}

    public mutating func begin(settlingDuration: TimeInterval, holding: Bool = false) {
        beginning = last
        elapsed = 0
        settling = settlingDuration.isFinite ? min(1, max(0.002, settlingDuration)) : 0.002
        hasResumed = false
        self.holding = holding
        isTransitioning = true
    }

    public mutating func reset() { self = Self() }

    public mutating func process(_ frame: PCMFrame) -> PCMFrame {
        guard frame.frameCount > 0, frame.format.isValid else { return frame }
        var result = frame
        let channels = frame.format.channelCount
        if isTransitioning {
            for index in 0..<frame.frameCount {
                if holding, elapsed >= 0.002 {
                    for channel in 0..<channels { result.samples[index * channels + channel] = 0 }
                    continue
                }
                if elapsed >= settling, !hasResumed {
                    // Native graph reconfiguration may return silence beyond
                    // its advertised DSP latency. Fade the first returning
                    // sample, without holding or shifting any input sample.
                    guard (0..<channels).contains(where: { frame.samples[index * channels + $0] != 0 }) else { continue }
                    hasResumed = true
                    elapsed = settling
                }
                if elapsed >= settling + 0.002 { isTransitioning = false; break }
                for channel in 0..<channels {
                    let position = index * channels + channel
                    if elapsed < 0.002 {
                        result.samples[position] = (channel < beginning.count ? beginning[channel] : 0)
                            * Float(1 - elapsed / 0.002)
                    } else if elapsed < settling {
                        result.samples[position] = 0
                    } else {
                        result.samples[position] *= Float(min(1, (elapsed - settling) / 0.002))
                    }
                }
                elapsed += 1 / frame.format.sampleRate
            }
        }
        last = Array(result.samples.suffix(channels))
        return result
    }
}
