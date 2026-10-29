import AudioCore
import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

public final class AudioOutputStreamRenderer {
    private let backend: AudioOutputStreamBackend
    private var runtimeEventHandler: ((AudioStreamRuntimeEvent) -> Void)?
    private var isRunning = false
    private var scheduledFrameCount: UInt64 = 0
    private var actualHardwareFormat: AudioFormat
    public private(set) var configuration: AudioOutputStreamConfiguration

    public init(
        configuration: AudioOutputStreamConfiguration = AudioOutputStreamConfiguration(),
        backend: AudioOutputStreamBackend
    ) {
        self.configuration = configuration
        self.backend = backend
        self.actualHardwareFormat = configuration.preferredFormat
    }

    #if canImport(AVFAudio)
    public convenience init(
        configuration: AudioOutputStreamConfiguration = AudioOutputStreamConfiguration(),
        engine: AVAudioEngine = AVAudioEngine(),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode()
    ) {
        self.init(
            configuration: configuration,
            backend: SystemAudioOutputStreamBackend(engine: engine, playerNode: playerNode)
        )
    }
    #endif

    public func setRuntimeEventHandler(_ handler: ((AudioStreamRuntimeEvent) -> Void)?) {
        runtimeEventHandler = handler
    }

    @discardableResult
    public func start(configuration requestedConfiguration: AudioOutputStreamConfiguration? = nil) -> AudioStreamOperationReport {
        guard !isRunning else {
            return emitReport(.startOutputRenderer, .ignored(.alreadyRunning))
        }
        if let requestedConfiguration { configuration = requestedConfiguration }
        do {
            actualHardwareFormat = try backend.startRendering(configuration: configuration)
            isRunning = true
            return emitReport(.startOutputRenderer, .applied)
        } catch {
            do { try backend.stopRendering() } catch {
                _ = emitReport(.stopOutputRenderer, AudioInputStreamCapture.operationResult(for: error))
            }
            return emitReport(.startOutputRenderer, AudioInputStreamCapture.operationResult(for: error))
        }
    }

    @discardableResult
    public func stop() -> AudioStreamOperationReport {
        guard isRunning else {
            return emitReport(.stopOutputRenderer, .ignored(.alreadyStopped))
        }
        do {
            try backend.stopRendering()
            isRunning = false
            return emitReport(.stopOutputRenderer, .applied)
        } catch {
            return emitReport(.stopOutputRenderer, AudioInputStreamCapture.operationResult(for: error))
        }
    }

    @discardableResult
    public func schedule(_ frame: PCMFrame) -> AudioStreamOperationReport {
        guard isRunning else {
            return emitReport(.scheduleOutputFrame, .ignored(.alreadyStopped))
        }
        guard frame.format == actualHardwareFormat else {
            return emitReport(
                .scheduleOutputFrame,
                .failed(.hardwareFormatMismatch(expected: actualHardwareFormat, actual: frame.format))
            )
        }
        do {
            _ = try frame.validated()
            try backend.schedule(frame)
            scheduledFrameCount += 1
            let report = emitReport(.scheduleOutputFrame, .applied)
            runtimeEventHandler?(.outputFrameScheduled(frame))
            return report
        } catch {
            return emitReport(.scheduleOutputFrame, AudioInputStreamCapture.operationResult(for: error))
        }
    }

    private func snapshot() -> AudioStreamSnapshot {
        AudioStreamSnapshot(
            direction: .output,
            isRunning: isRunning,
            preferredFormat: configuration.preferredFormat,
            actualHardwareFormat: actualHardwareFormat,
            processedFrameCount: scheduledFrameCount,
            bufferedOutputDuration: backend.bufferedOutputDuration,
            playbackResetCount: backend.playbackResetCount
        )
    }

    private func emitReport(
        _ operation: AudioStreamOperation,
        _ result: AudioStreamOperationResult
    ) -> AudioStreamOperationReport {
        let report = AudioStreamOperationReport(
            operation: operation,
            result: result,
            snapshot: snapshot()
        )
        runtimeEventHandler?(.operation(report))
        return report
    }
}
