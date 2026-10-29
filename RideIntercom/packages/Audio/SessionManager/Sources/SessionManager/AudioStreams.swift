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
    public var maximumBufferedDuration: TimeInterval?

    public init(preferredFormat: AudioFormat = AudioFormat(), maximumBufferedDuration: TimeInterval? = nil) {
        self.preferredFormat = preferredFormat
        self.maximumBufferedDuration = maximumBufferedDuration
    }
}

public struct AudioStreamSnapshot: Codable, Equatable, Sendable {
    public var direction: AudioStreamDirection
    public var isRunning: Bool
    public var preferredFormat: AudioFormat
    public var actualHardwareFormat: AudioFormat
    public var processedFrameCount: UInt64
    public var bufferedOutputDuration: TimeInterval?
    public var playbackResetCount: Int?
    public var inputVoiceProcessing: AudioInputVoiceProcessingConfiguration?

    public init(
        direction: AudioStreamDirection,
        isRunning: Bool,
        preferredFormat: AudioFormat,
        actualHardwareFormat: AudioFormat,
        processedFrameCount: UInt64,
        inputVoiceProcessing: AudioInputVoiceProcessingConfiguration? = nil,
        bufferedOutputDuration: TimeInterval? = nil,
        playbackResetCount: Int? = nil
    ) {
        self.direction = direction
        self.isRunning = isRunning
        self.preferredFormat = preferredFormat
        self.actualHardwareFormat = actualHardwareFormat
        self.processedFrameCount = processedFrameCount
        self.inputVoiceProcessing = inputVoiceProcessing
        self.bufferedOutputDuration = bufferedOutputDuration
        self.playbackResetCount = playbackResetCount
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
    #if canImport(AVFAudio)
    /// Optional graph destination. A mixer on this engine renders directly on
    /// the output device clock instead of crossing a second PCM player queue.
    var renderingEngine: AVAudioEngine? { get }
    #endif
    var bufferedOutputDuration: TimeInterval? { get }
    var playbackResetCount: Int? { get }
    func startRendering(configuration: AudioOutputStreamConfiguration) throws -> AudioFormat
    func stopRendering() throws
    func schedule(_ frame: PCMFrame) throws
}

public extension AudioOutputStreamBackend {
    #if canImport(AVFAudio)
    var renderingEngine: AVAudioEngine? { nil }
    #endif
    var bufferedOutputDuration: TimeInterval? { nil }
    var playbackResetCount: Int? { nil }
}
