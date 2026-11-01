import AudioCore
import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

public final class AudioInputStreamCapture {
    private let backend: AudioInputStreamBackend
    private var runtimeEventHandler: ((AudioStreamRuntimeEvent) -> Void)?
    private let stateLock = NSRecursiveLock()
    private var generation = UUID()
    private var isRunning = false
    // Native voice-processing mute is not available on every configuration.
    // Keep the PCM delivery boundary closed independently of that native option.
    private var inputMuted: Bool
    private var capturedFrameCount: UInt64 = 0
    private var actualHardwareFormat: AudioFormat
    public private(set) var configuration: AudioInputStreamConfiguration

    public init(
        configuration: AudioInputStreamConfiguration = AudioInputStreamConfiguration(),
        backend: AudioInputStreamBackend
    ) {
        self.configuration = configuration
        self.backend = backend
        self.actualHardwareFormat = configuration.preferredFormat
        self.inputMuted = configuration.voiceProcessing.inputMuted
    }

    #if canImport(AVFAudio)
    public convenience init(
        configuration: AudioInputStreamConfiguration = AudioInputStreamConfiguration(),
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.init(
            configuration: configuration,
            backend: SystemAudioInputStreamBackend(engine: engine)
        )
    }
    #endif

    public func setRuntimeEventHandler(_ handler: ((AudioStreamRuntimeEvent) -> Void)?) {
        stateLock.withLock { runtimeEventHandler = handler }
    }

    @discardableResult
    public func start() -> AudioStreamOperationReport {
        guard stateLock.withLock({ !isRunning }) else {
            return emitReport(.startInputCapture, .ignored(.alreadyRunning))
        }
        let generation = stateLock.withLock {
            self.generation = UUID()
            return self.generation
        }
        let processing = applyVoiceProcessing(configuration.voiceProcessing)
        if case .failed = processing.result {
            stateLock.withLock { self.generation = UUID() }
            do { try backend.stopCapture() } catch { _ = emitReport(.stopInputCapture, Self.operationResult(for: error)) }
            return emitReport(.startInputCapture, processing.result)
        }
        do {
            let hardwareFormat = try backend.startCapture(configuration: configuration) { [weak self] frame in
                self?.handleCapturedFrame(frame, generation: generation)
            }
            stateLock.withLock {
                actualHardwareFormat = hardwareFormat
                isRunning = true
            }
            return emitReport(.startInputCapture, .applied)
        } catch {
            stateLock.withLock { self.generation = UUID(); isRunning = false }
            do { try backend.stopCapture() } catch {
                _ = emitReport(.stopInputCapture, Self.operationResult(for: error))
            }
            return emitReport(.startInputCapture, Self.operationResult(for: error))
        }
    }

    @discardableResult
    public func stop() -> AudioStreamOperationReport {
        guard stateLock.withLock({ isRunning }) else {
            return emitReport(.stopInputCapture, .ignored(.alreadyStopped))
        }
        stateLock.withLock { generation = UUID() }
        do {
            try backend.stopCapture()
            stateLock.withLock { isRunning = false }
            return emitReport(.stopInputCapture, .applied)
        } catch {
            return emitReport(.stopInputCapture, Self.operationResult(for: error))
        }
    }

    @discardableResult
    public func updateVoiceProcessing(
        _ voiceProcessing: AudioInputVoiceProcessingConfiguration
    ) -> AudioStreamOperationReport {
        let changesIOMode = effectiveVoiceProcessingEnabled(configuration.voiceProcessing)
            != effectiveVoiceProcessingEnabled(voiceProcessing)
        stateLock.withLock {
            configuration.voiceProcessing = voiceProcessing
            if voiceProcessing.inputMuted { inputMuted = true }
        }
        guard stateLock.withLock({ isRunning }) else {
            // Keep desired settings, but do not open I/O while capture is stopped.
            // start() applies the latest configuration before starting the backend.
            return emitReport(.updateInputVoiceProcessing(voiceProcessing), .ignored(.alreadyStopped))
        }
        if changesIOMode {
            // AVAudioIONode cannot switch between RemoteIO and VoiceProcessingIO
            // while running. Reopen the tap too: this can change hardware format.
            let stopped = stop()
            if case .failed = stopped.result {
                return emitReport(.updateInputVoiceProcessing(voiceProcessing), stopped.result)
            }
            let restarted = start()
            return emitReport(.updateInputVoiceProcessing(voiceProcessing), restarted.result)
        }
        return applyVoiceProcessing(voiceProcessing)
    }

    private func effectiveVoiceProcessingEnabled(_ configuration: AudioInputVoiceProcessingConfiguration) -> Bool {
        configuration.soundIsolationEnabled || (configuration.otherAudioDuckingEnabled
            && !backend.unsupportedVoiceProcessingSettings.contains(.advancedDucking))
    }

    @discardableResult
    private func applyVoiceProcessing(
        _ voiceProcessing: AudioInputVoiceProcessingConfiguration
    ) -> AudioStreamOperationReport {
        do {
            try backend.updateVoiceProcessing(voiceProcessing)
            stateLock.withLock { inputMuted = voiceProcessing.inputMuted }
            return emitReport(.updateInputVoiceProcessing(voiceProcessing), .applied)
        } catch {
            let result = Self.operationResult(for: error)
            // The software boundary still implements mute when the backend has
            // no voice processing. Real native errors must not reopen input.
            if case .ignored(.unsupportedOnCurrentPlatform) = result {
                stateLock.withLock { inputMuted = voiceProcessing.inputMuted }
            }
            return emitReport(.updateInputVoiceProcessing(voiceProcessing), result)
        }
    }

    private func handleCapturedFrame(_ frame: PCMFrame, generation: UUID) {
        let handler: ((AudioStreamRuntimeEvent) -> Void)? = stateLock.withLock {
            guard isRunning, !inputMuted, self.generation == generation else { return nil }
            actualHardwareFormat = frame.format
            capturedFrameCount += 1
            return runtimeEventHandler
        }
        handler?(.inputFrame(frame))
    }

    private func snapshot() -> AudioStreamSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return AudioStreamSnapshot(
            direction: .input,
            isRunning: isRunning,
            preferredFormat: configuration.preferredFormat,
            actualHardwareFormat: actualHardwareFormat,
            processedFrameCount: capturedFrameCount,
            inputVoiceProcessing: configuration.voiceProcessing,
            inputDeliveryMuted: inputMuted,
            unsupportedInputVoiceProcessingSettings: configuration.voiceProcessing.otherAudioDuckingEnabled
                ? backend.unsupportedVoiceProcessingSettings : []
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
        let handler = stateLock.withLock { runtimeEventHandler }
        handler?(.operation(report))
        return report
    }
}

extension AudioInputStreamCapture {
    static func operationResult(for error: Error) -> AudioStreamOperationResult {
        if let error = error as? AudioStreamError {
            switch error {
            case .unsupportedOnCurrentPlatform:
                return .ignored(.unsupportedOnCurrentPlatform)
            case .invalidFrame(let message):
                return .failed(.invalidFrame(message))
            case .hardwareFormatMismatch(let expected, let actual):
                return .failed(.hardwareFormatMismatch(expected: expected, actual: actual))
            case .engineOperationFailed(let message):
                return .failed(.engineOperationFailed(message))
            }
        }
        if let error = error as? AudioProcessingFailure {
            return .failed(.invalidFrame(error.reason))
        }
        if let error = error as? AudioSessionManagerError {
            switch error {
            case .operationUnsupportedOnCurrentPlatform:
                return .ignored(.unsupportedOnCurrentPlatform)
            case .coreAudioOperationFailed(let message):
                return .failed(.engineOperationFailed(message))
            case .echoCancelledInputRequiresDefaultMode:
                return .failed(.invalidFrame("echo cancelled input requires default mode"))
            case .inputSelectionUnsupported, .outputSelectionUnsupported, .deviceNotFound:
                return .failed(.unexpected(String(describing: error)))
            }
        }
        return .failed(.unexpected(String(describing: error)))
    }
}
