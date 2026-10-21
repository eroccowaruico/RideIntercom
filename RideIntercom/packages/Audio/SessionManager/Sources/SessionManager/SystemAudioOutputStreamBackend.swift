import AudioCore
import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if canImport(AVFAudio)
public final class SystemAudioOutputStreamBackend: AudioOutputStreamBackend {
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private var isGraphConfigured = false
    private var configuredHardwareFormat: AudioFormat?
    private var maximumBufferedDuration: TimeInterval?
    private var scheduledEndSample: AVAudioFramePosition = 0
    private var resetCount = 0
    public var playbackResetCount: Int? { resetCount }
    private var renderedSample: AVAudioFramePosition {
        playerNode.lastRenderTime.flatMap { time in
                guard time.isSampleTimeValid || time.isHostTimeValid,
                      let played = playerNode.playerTime(forNodeTime: time), played.isSampleTimeValid else { return nil }
                return played.sampleTime
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
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
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
        engine.stop()
    }

    public func schedule(_ frame: PCMFrame) throws {
        let buffer = try frame.makePCMBuffer()
        var shouldResumePlayback = false
        if let limit = maximumBufferedDuration {
            let duration = Double(buffer.frameLength) / frame.format.sampleRate
            guard duration <= limit else { throw AudioStreamError.invalidFrame("Frame exceeds live playback budget") }
            if (bufferedOutputDuration ?? 0) + duration > limit {
                shouldResumePlayback = playerNode.isPlaying
                playerNode.stop()
                scheduledEndSample = 0
                resetCount += 1
            }
        }
        scheduledEndSample = max(scheduledEndSample, renderedSample) + AVAudioFramePosition(buffer.frameLength)
        playerNode.scheduleBuffer(buffer, at: nil, options: [])
        // Starting an empty player advances its timeline before the replacement
        // buffer is available. Queue first so the next render begins with it.
        if shouldResumePlayback { playerNode.play() }
    }
}

#endif
