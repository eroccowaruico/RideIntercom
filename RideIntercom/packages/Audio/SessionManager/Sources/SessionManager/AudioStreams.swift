import AudioCore
import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

public enum AudioStreamDirection: Codable, Equatable, Sendable {
    case input
    case output
}

public struct AudioInputStreamConfiguration: Codable, Equatable, Sendable {
    public var preferredFormat: AudioFormat
    public var bufferFrameCount: UInt32
    public var voiceProcessing: AudioInputVoiceProcessingConfiguration

    public init(
        preferredFormat: AudioFormat = AudioFormat(),
        bufferFrameCount: UInt32 = 128,
        voiceProcessing: AudioInputVoiceProcessingConfiguration = AudioInputVoiceProcessingConfiguration()
    ) {
        self.preferredFormat = preferredFormat
        self.bufferFrameCount = max(1, bufferFrameCount)
        self.voiceProcessing = voiceProcessing
    }
}

public struct AudioOutputStreamConfiguration: Codable, Equatable, Sendable {
    public var preferredFormat: AudioFormat

    public init(preferredFormat: AudioFormat = AudioFormat()) {
        self.preferredFormat = preferredFormat
    }
}

public struct AudioStreamSnapshot: Codable, Equatable, Sendable {
    public var direction: AudioStreamDirection
    public var isRunning: Bool
    public var preferredFormat: AudioFormat
    public var actualHardwareFormat: AudioFormat
    public var processedFrameCount: UInt64
    public var inputVoiceProcessing: AudioInputVoiceProcessingConfiguration?

    public init(
        direction: AudioStreamDirection,
        isRunning: Bool,
        preferredFormat: AudioFormat,
        actualHardwareFormat: AudioFormat,
        processedFrameCount: UInt64,
        inputVoiceProcessing: AudioInputVoiceProcessingConfiguration? = nil
    ) {
        self.direction = direction
        self.isRunning = isRunning
        self.preferredFormat = preferredFormat
        self.actualHardwareFormat = actualHardwareFormat
        self.processedFrameCount = processedFrameCount
        self.inputVoiceProcessing = inputVoiceProcessing
    }
}

public enum AudioStreamOperation: Codable, Equatable, Sendable {
    case startInputCapture
    case stopInputCapture
    case updateInputVoiceProcessing(AudioInputVoiceProcessingConfiguration)
    case startOutputRenderer
    case stopOutputRenderer
    case scheduleOutputFrame
}

public enum AudioStreamIgnoredReason: Codable, Equatable, Sendable {
    case alreadyRunning
    case alreadyStopped
    case unsupportedOnCurrentPlatform
}

public enum AudioStreamOperationFailure: Codable, Equatable, Sendable {
    case invalidFrame(String)
    case hardwareFormatMismatch(expected: AudioFormat, actual: AudioFormat)
    case engineOperationFailed(String)
    case unexpected(String)
}

public enum AudioStreamOperationResult: Codable, Equatable, Sendable {
    case applied
    case ignored(AudioStreamIgnoredReason)
    case failed(AudioStreamOperationFailure)
}

public struct AudioStreamOperationReport: Codable, Equatable, Sendable {
    public var operation: AudioStreamOperation
    public var result: AudioStreamOperationResult
    public var snapshot: AudioStreamSnapshot

    public init(
        operation: AudioStreamOperation,
        result: AudioStreamOperationResult,
        snapshot: AudioStreamSnapshot
    ) {
        self.operation = operation
        self.result = result
        self.snapshot = snapshot
    }
}

public enum AudioStreamRuntimeEvent: Codable, Equatable, Sendable {
    case operation(AudioStreamOperationReport)
    case inputFrame(PCMFrame)
    case outputFrameScheduled(PCMFrame)
}

public enum AudioStreamError: Error, Equatable, Sendable {
    case unsupportedOnCurrentPlatform
    case invalidFrame(String)
    case hardwareFormatMismatch(expected: AudioFormat, actual: AudioFormat)
    case engineOperationFailed(String)
}

public protocol AudioInputStreamBackend: AnyObject {
    func startCapture(
        configuration: AudioInputStreamConfiguration,
        onFrame: @escaping (PCMFrame) -> Void
    ) throws -> AudioFormat
    func updateVoiceProcessing(_ configuration: AudioInputVoiceProcessingConfiguration) throws
    func stopCapture() throws
}

public extension AudioInputStreamBackend {
    func updateVoiceProcessing(_ configuration: AudioInputVoiceProcessingConfiguration) throws {
        _ = configuration
        throw AudioStreamError.unsupportedOnCurrentPlatform
    }
}

public protocol AudioOutputStreamBackend: AnyObject {
    func startRendering(configuration: AudioOutputStreamConfiguration) throws -> AudioFormat
    func stopRendering() throws
    func schedule(_ frame: PCMFrame) throws
}

public final class AudioInputStreamCapture {
    private let backend: AudioInputStreamBackend
    private var runtimeEventHandler: ((AudioStreamRuntimeEvent) -> Void)?
    private let stateLock = NSRecursiveLock()
    private var generation = UUID()
    private var isRunning = false
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
        applyVoiceProcessing(configuration.voiceProcessing)
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
        stateLock.withLock { configuration.voiceProcessing = voiceProcessing }
        return applyVoiceProcessing(voiceProcessing)
    }

    @discardableResult
    private func applyVoiceProcessing(
        _ voiceProcessing: AudioInputVoiceProcessingConfiguration
    ) -> AudioStreamOperationReport {
        do {
            try backend.updateVoiceProcessing(voiceProcessing)
            return emitReport(.updateInputVoiceProcessing(voiceProcessing), .applied)
        } catch {
            return emitReport(.updateInputVoiceProcessing(voiceProcessing), Self.operationResult(for: error))
        }
    }

    private func handleCapturedFrame(_ frame: PCMFrame, generation: UUID) {
        stateLock.withLock {
            guard isRunning, self.generation == generation else { return }
            actualHardwareFormat = frame.format
            capturedFrameCount += 1
            runtimeEventHandler?(.inputFrame(frame))
        }
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
            inputVoiceProcessing: configuration.voiceProcessing
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
        stateLock.withLock { runtimeEventHandler?(.operation(report)) }
        return report
    }
}

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
    public func start() -> AudioStreamOperationReport {
        guard !isRunning else {
            return emitReport(.startOutputRenderer, .ignored(.alreadyRunning))
        }
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
            processedFrameCount: scheduledFrameCount
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

private extension AudioInputStreamCapture {
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

#if canImport(AVFAudio)
public final class SystemAudioInputStreamBackend: AudioInputStreamBackend {
    private let engine: AVAudioEngine
    private let bus: AVAudioNodeBus
    private var voiceProcessingManager: AudioInputVoiceProcessingManager?
    private var openedInputNode: AVAudioInputNode?
    private var nextSequenceNumber: UInt64 = 0

    public init(
        engine: AVAudioEngine = AVAudioEngine(),
        bus: AVAudioNodeBus = 0,
        voiceProcessingManager: AudioInputVoiceProcessingManager? = nil
    ) {
        self.engine = engine
        self.bus = bus
        // Constructing a stream must not initialize hardware or ask the audio service to open I/O.
        self.voiceProcessingManager = voiceProcessingManager
    }

    public func startCapture(
        configuration: AudioInputStreamConfiguration,
        onFrame: @escaping (PCMFrame) -> Void
    ) throws -> AudioFormat {
        let inputNode = engine.inputNode
        openedInputNode = inputNode
        let inputFormat = inputNode.outputFormat(forBus: bus)
        let hardwareFormat = AudioFormat(avAudioFormat: inputFormat, fallback: configuration.preferredFormat)
        inputNode.removeTap(onBus: bus)
        inputNode.installTap(
            onBus: bus,
            bufferSize: configuration.bufferFrameCount,
            format: inputFormat
        ) { [weak self] buffer, time in
            guard let self,
                  let frame = PCMFrame(
                    buffer: buffer,
                    sequenceNumber: self.nextSequenceNumber,
                    capturedAt: time.hostTime == 0 ? Date().timeIntervalSince1970 : AVAudioTime.seconds(forHostTime: time.hostTime)
                  )
            else { return }
            self.nextSequenceNumber += 1
            onFrame(frame)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: bus)
            throw AudioStreamError.engineOperationFailed(error.localizedDescription)
        }
        return hardwareFormat
    }

    public func updateVoiceProcessing(_ configuration: AudioInputVoiceProcessingConfiguration) throws {
        #if os(iOS)
        if voiceProcessingManager == nil {
            let inputNode = engine.inputNode
            openedInputNode = inputNode
            voiceProcessingManager = AudioInputVoiceProcessingManager(
                backend: SystemAudioInputVoiceProcessingBackend(inputNode: inputNode)
            )
        }
        try voiceProcessingManager?.configure(configuration)
        #else
        _ = configuration
        throw AudioStreamError.unsupportedOnCurrentPlatform
        #endif
    }

    public func stopCapture() throws {
        openedInputNode?.removeTap(onBus: bus)
        engine.stop()
    }
}

public final class SystemAudioOutputStreamBackend: AudioOutputStreamBackend {
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private var isGraphConfigured = false
    private var configuredHardwareFormat: AudioFormat?

    public init(
        engine: AVAudioEngine = AVAudioEngine(),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode()
    ) {
        self.engine = engine
        self.playerNode = playerNode
    }

    public func startRendering(configuration: AudioOutputStreamConfiguration) throws -> AudioFormat {
        let hardwareFormat = AudioFormat(
            avAudioFormat: engine.outputNode.inputFormat(forBus: 0),
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
        engine.stop()
    }

    public func schedule(_ frame: PCMFrame) throws {
        let buffer = try frame.makePCMBuffer()
        playerNode.scheduleBuffer(buffer, at: nil, options: [])
    }
}

private extension AVAudioFormat {
    convenience init?(audioFormat: AudioFormat) {
        self.init(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioFormat.sampleRate,
            channels: AVAudioChannelCount(audioFormat.channelCount),
            interleaved: false
        )
    }
}

extension PCMFrame {
    init?(
        buffer: AVAudioPCMBuffer,
        sequenceNumber: UInt64,
        capturedAt: TimeInterval
    ) {
        guard let channelData = buffer.floatChannelData else { return nil }
        let format = AudioFormat(avAudioFormat: buffer.format)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            self.init(sequenceNumber: sequenceNumber, format: format, capturedAt: capturedAt, samples: [])
            return
        }

        let channelCount = Int(buffer.format.channelCount)
        var samples: [Float] = []
        samples.reserveCapacity(frameLength * channelCount)
        for frameIndex in 0..<frameLength {
            for channelIndex in 0..<channelCount {
                samples.append(channelData[channelIndex][frameIndex])
            }
        }
        self.init(
            sequenceNumber: sequenceNumber,
            format: format,
            capturedAt: capturedAt,
            samples: samples
        )
    }

    func makePCMBuffer() throws -> AVAudioPCMBuffer {
        guard samples.count.isMultiple(of: format.channelCount) else {
            throw AudioStreamError.invalidFrame("sample count is not divisible by channel count")
        }
        guard let avFormat = AVAudioFormat(audioFormat: format),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: avFormat,
                frameCapacity: AVAudioFrameCount(samples.count / format.channelCount)
              ),
              let channelData = buffer.floatChannelData
        else {
            throw AudioStreamError.invalidFrame("failed to create PCM buffer")
        }

        let frameCount = samples.count / format.channelCount
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<format.channelCount {
                channelData[channelIndex][frameIndex] = samples[frameIndex * format.channelCount + channelIndex]
            }
        }
        return buffer
    }
}

private extension AudioFormat {
    init(avAudioFormat: AVAudioFormat, fallback: AudioFormat = AudioFormat()) {
        let sampleRate = avAudioFormat.sampleRate
        let channelCount = Int(avAudioFormat.channelCount)
        if sampleRate > 0, channelCount > 0 {
            self.init(sampleRate: sampleRate, channelCount: channelCount)
        } else {
            self = fallback
        }
    }
}
#endif
