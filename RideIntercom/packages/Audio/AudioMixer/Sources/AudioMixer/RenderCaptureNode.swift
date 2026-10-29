import AudioCore
import AVFAudio
import Synchronization

/// The last native render block is already committed, even when its host
/// timestamp is still in the future. Schedule beyond its end, not its start.
final class MixerRenderClock: Sendable {
    let frameCount = Atomic<Int>(0)
}

/// Apple's unity EQ supplies a post-render callback at the engine quantum.
/// AVAudioNode taps batch about 100 ms even when bufferSize is much smaller.
final class RenderCaptureNode {
    let node = AVAudioUnitEQ(numberOfBands: 0)
    private let state: RenderState
    var droppedFrameCount: Int { state.capture.droppedFrameCount }

    init(format: AudioFormat, renderClock: MixerRenderClock, onFrame: @escaping (PCMFrame) -> Void) throws {
        state = RenderState(format: format, renderClock: renderClock, onFrame: onFrame)
        let status = AudioUnitAddRenderNotify(node.audioUnit, Self.receive, Unmanaged.passUnretained(state).toOpaque())
        guard status == noErr else { throw AudioMixerError.pcmSinkInstallFailed("Render notification failed: \(status)") }
    }

    func beginTransition(settlingDuration: TimeInterval, holding: Bool = false) {
        state.begin(settlingDuration: settlingDuration, holding: holding)
    }

    deinit {
        state.capture.finish()
        AudioUnitRemoveRenderNotify(node.audioUnit, Self.receive, Unmanaged.passUnretained(state).toOpaque())
    }

    private static let receive: AURenderCallback = { context, flags, time, _, count, data in
        if flags.pointee.contains(.unitRenderAction_PostRender),
           !flags.pointee.contains(.unitRenderAction_PostRenderError), let data {
            let state = Unmanaged<RenderState>.fromOpaque(context).takeUnretainedValue()
            state.process(count: Int(count), data: data, flags: flags)
            state.capture.receive(timestamp: time.pointee, frameCount: count, data: UnsafePointer(data))
        }
        return noErr
    }
}

/// All sample state belongs to the render thread. The serial graph owner only
/// posts an atomic request. Memory is allocated once, never in the callback.
private final class RenderState {
    let capture: AudioRenderCapture
    private let renderClock: MixerRenderClock
    private let rate: Double
    private let fadeFrames: Int
    private let channels: Int
    private let last: UnsafeMutablePointer<Float>
    private let beginning: UnsafeMutablePointer<Float>
    private let requestedFrames = Atomic<Int>(-1)
    private var elapsed = 0
    private var settling = 0
    private var transitioning = false
    private var hasResumed = false
    private var holding = false

    init(format: AudioFormat, renderClock: MixerRenderClock, onFrame: @escaping (PCMFrame) -> Void) {
        self.renderClock = renderClock
        capture = AudioRenderCapture(format: format, onFrame: onFrame)
        rate = format.sampleRate
        channels = format.channelCount
        fadeFrames = max(1, Int((rate * 0.002).rounded()))
        last = .allocate(capacity: channels); last.initialize(repeating: 0, count: channels)
        beginning = .allocate(capacity: channels); beginning.initialize(repeating: 0, count: channels)
    }
    deinit { last.deallocate(); beginning.deallocate() }

    func begin(settlingDuration: TimeInterval, holding: Bool = false) {
        let duration = settlingDuration.isFinite ? min(1, max(0.002, settlingDuration)) : 0.002
        requestedFrames.store(holding ? -2 : max(fadeFrames, Int((rate * duration).rounded())), ordering: .releasing)
    }

    func process(count: Int, data: UnsafeMutablePointer<AudioBufferList>, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>) {
        renderClock.frameCount.store(count, ordering: .relaxed)
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        guard count > 0, buffers.count == channels,
              buffers.allSatisfy({ $0.mData != nil && $0.mDataByteSize >= count * MemoryLayout<Float>.size }) else { return }
        let requested = requestedFrames.exchange(-1, ordering: .acquiring)
        if requested != -1 {
            for channel in 0..<channels { beginning[channel] = last[channel] }
            holding = requested == -2
            settling = max(fadeFrames, requested); elapsed = 0; transitioning = true; hasResumed = false
        }
        if transitioning {
            for index in 0..<count {
                if holding, elapsed >= fadeFrames {
                    for channel in 0..<channels {
                        buffers[channel].mData!.assumingMemoryBound(to: Float.self)[index] = 0
                    }
                    continue
                }
                if elapsed >= settling, !hasResumed {
                    let audible = (0..<channels).contains {
                        buffers[$0].mData!.assumingMemoryBound(to: Float.self)[index] != 0
                    }
                    if !audible { continue }
                    hasResumed = true
                    elapsed = settling
                }
                if elapsed >= settling + fadeFrames { transitioning = false; break }
                for channel in 0..<channels {
                    let samples = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                    if elapsed < fadeFrames {
                        samples[index] = beginning[channel] * Float(1 - Double(elapsed) / Double(fadeFrames))
                    } else if elapsed < settling {
                        samples[index] = 0
                    } else {
                        samples[index] *= Float(Double(elapsed - settling) / Double(fadeFrames))
                    }
                }
                elapsed += 1
            }
            // A fade of the previous sample can produce output even if the
            // upstream effect marked its newly rendered block as silent.
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
        }
        for channel in 0..<channels {
            last[channel] = buffers[channel].mData!.assumingMemoryBound(to: Float.self)[count - 1]
        }
    }
}
