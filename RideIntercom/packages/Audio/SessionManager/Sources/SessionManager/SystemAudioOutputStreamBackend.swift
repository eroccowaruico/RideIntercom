import AudioCore
import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if canImport(AVFAudio)
public final class SystemAudioOutputStreamBackend: AudioOutputStreamBackend {
    private let engine: AVAudioEngine
    public var renderingEngine: AVAudioEngine? { engine }
    private let playerNode: AVAudioPlayerNode
    private var isGraphConfigured = false
    private var configuredHardwareFormat: AudioFormat?
    private var maximumBufferedDuration: TimeInterval?
    private var scheduledEndSample: AVAudioFramePosition = 0
    private var lastAudibleEndSample: AVAudioFramePosition = 0
    private var usesExplicitTimeline = false
    private var resetCount = 0
    public var playbackResetCount: Int? { resetCount }
    private var renderedSample: AVAudioFramePosition {
        playerNode.lastRenderTime.flatMap { time in
                guard time.isSampleTimeValid || time.isHostTimeValid,
                      let played = playerNode.playerTime(forNodeTime: time), played.isSampleTimeValid else { return nil }
                // lastRenderTime is a snapshot from the previous render quantum.
                // In realtime mode the device clock has advanced since then; counting
                // those already elapsed samples as queued audio can interrupt a
                // healthy 100 ms tap batch. Offline rendering advances only explicitly.
                let elapsed = !engine.isInManualRenderingMode && engine.isRunning && playerNode.isPlaying && time.isHostTimeValid
                    ? max(0, ProcessInfo.processInfo.systemUptime - AVAudioTime.seconds(forHostTime: time.hostTime)) : 0
                return played.sampleTime + AVAudioFramePosition(elapsed * played.sampleRate)
            } ?? 0
    }
    public var bufferedOutputDuration: TimeInterval? {
        guard let format = configuredHardwareFormat else { return nil }
        return Double(max(0, scheduledEndSample - renderedSample)) / format.sampleRate
    }

    public init(
        engine: AVAudioEngine = AVAudioEngine(),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode()
    ) {
        self.engine = engine
        self.playerNode = playerNode
    }

    public func startRendering(configuration: AudioOutputStreamConfiguration) throws -> AudioFormat {
        if let limit = configuration.maximumBufferedDuration, !limit.isFinite || limit <= 0 {
            throw AudioStreamError.invalidFrame("Invalid playback budget")
        }
        maximumBufferedDuration = configuration.maximumBufferedDuration
        let hardwareFormat = AudioFormat(
            avAudioFormat: engine.isInManualRenderingMode ? engine.manualRenderingFormat : engine.outputNode.inputFormat(forBus: 0),
            fallback: configuration.preferredFormat
        )
        if !isGraphConfigured || configuredHardwareFormat != hardwareFormat {
            if !engine.attachedNodes.contains(playerNode) {
                engine.attach(playerNode)
            }
            guard let format = AVAudioFormat(audioFormat: hardwareFormat) else {
                throw AudioStreamError.invalidFrame("failed to create output format")
            }
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, fromBus: 0,
                toBus: engine.mainMixerNode.nextAvailableInputBus, format: format)
            isGraphConfigured = true
            configuredHardwareFormat = hardwareFormat
        }
        engine.prepare()
        do {
            if !engine.isRunning {
                try engine.start()
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
        } catch {
            throw AudioStreamError.engineOperationFailed(error.localizedDescription)
        }
        return hardwareFormat
    }

    public func stopRendering() throws {
        playerNode.stop()
        scheduledEndSample = 0
        lastAudibleEndSample = 0
        usesExplicitTimeline = false
        engine.stop()
    }

    public func schedule(_ frame: PCMFrame) throws {
        let buffer = try frame.makePCMBuffer()
        let rendered = renderedSample
        let duration = Double(buffer.frameLength) / frame.format.sampleRate
        var energy: Float = 0, peak: Float = 0
        for sample in frame.samples { energy += sample * sample; peak = max(peak, abs(sample)) }
        let audible = energy >= Float(max(1, frame.samples.count)) * 0.0001 * 0.0001 || peak >= 0.001
        var options: AVAudioPlayerNodeBufferOptions = []
        if let limit = maximumBufferedDuration {
            guard duration <= limit else { throw AudioStreamError.invalidFrame("Frame exceeds live playback budget") }
            // Apply the latency budget to the wait before this frame starts.
            // Including the new frame itself interrupts ordinary capture batches
            // whenever their delivery overlaps the unplayed tail by a few ms.
            let queued = Double(max(0, scheduledEndSample - rendered)) / frame.format.sampleRate
            let canReleaseSilence = !audible && lastAudibleEndSample <= rendered && queued > max(0.01, duration)
            if canReleaseSilence {
                // at:nil after an interrupt can retain the old queue end. Keep
                // the running player clock and explicitly anchor this buffer
                // AND its successors. In realtime the current quantum may
                // already be rendering; reserve one incoming quantum of safety.
                options = .interrupts
                usesExplicitTimeline = true
                scheduledEndSample = rendered + (engine.isInManualRenderingMode ? 0 : AVAudioFramePosition(buffer.frameLength))
                resetCount += 1
            } else if queued >= limit {
                options = .interrupts
                usesExplicitTimeline = false
                scheduledEndSample = rendered
                resetCount += 1
            }
        }
        let startSample = max(scheduledEndSample, rendered)
        if options.isEmpty && scheduledEndSample <= rendered { usesExplicitTimeline = false }
        scheduledEndSample = startSample + AVAudioFramePosition(buffer.frameLength)
        if audible { lastAudibleEndSample = scheduledEndSample }
        let time = usesExplicitTimeline ? AVAudioTime(sampleTime: startSample, atRate: frame.format.sampleRate) : nil
        playerNode.scheduleBuffer(buffer, at: time, options: options)
    }
}

#endif
