import AudioCore
import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

/// Capture delivery may schedule from a worker while lifecycle runs elsewhere.
/// Native start/stop never holds the lock needed by a capture callback.
public final class AudioOutputStreamRenderer: @unchecked Sendable {
    private let backend: AudioOutputStreamBackend
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()
    private var runtimeEventHandler: ((AudioStreamRuntimeEvent) -> Void)?
    private var isRunning = false
    private var nativeStopPending = false
    private var scheduledFrameCount: UInt64 = 0
    private var actualHardwareFormat: AudioFormat
    private var currentConfiguration: AudioOutputStreamConfiguration
    private var bufferedDuration: TimeInterval?
    private var playbackResets: Int?
    #if canImport(AVFAudio)
    private var conversion = OutputPCMConversion()
    public var renderingEngine: AVAudioEngine? { backend.renderingEngine }
    #endif
    public var rendersToHardware: Bool { backend.rendersToHardware }
    public var configuration: AudioOutputStreamConfiguration { stateLock.withLock { currentConfiguration } }

    public init(configuration: AudioOutputStreamConfiguration = AudioOutputStreamConfiguration(),
                backend: AudioOutputStreamBackend) {
        currentConfiguration = configuration
        self.backend = backend
        actualHardwareFormat = configuration.preferredFormat
    }

    #if canImport(AVFAudio)
    public convenience init(configuration: AudioOutputStreamConfiguration = AudioOutputStreamConfiguration(),
                            engine: AVAudioEngine = AVAudioEngine(), playerNode: AVAudioPlayerNode = AVAudioPlayerNode()) {
        self.init(configuration: configuration, backend: SystemAudioOutputStreamBackend(engine: engine, playerNode: playerNode))
    }
    #endif

    public func setRuntimeEventHandler(_ handler: ((AudioStreamRuntimeEvent) -> Void)?) {
        stateLock.withLock { runtimeEventHandler = handler }
    }

    @discardableResult
    public func start(configuration requestedConfiguration: AudioOutputStreamConfiguration? = nil) -> AudioStreamOperationReport {
        var cleanupFailure: AudioStreamOperationResult?
        let result: AudioStreamOperationResult = lifecycleLock.withLock {
            let configuration: AudioOutputStreamConfiguration? = stateLock.withLock {
                guard !isRunning else { return nil }
                if let requestedConfiguration { currentConfiguration = requestedConfiguration }
                #if canImport(AVFAudio)
                conversion = OutputPCMConversion()
                #endif
                return currentConfiguration
            }
            guard let configuration else { return .ignored(.alreadyRunning) }
            if stateLock.withLock({ nativeStopPending }) {
                do {
                    try backend.stopRendering()
                    stateLock.withLock { nativeStopPending = false; updateBackendMetrics() }
                } catch { return AudioInputStreamCapture.operationResult(for: error) }
            }
            do {
                stateLock.withLock { nativeStopPending = true }
                let hardware = try backend.startRendering(configuration: configuration)
                stateLock.withLock {
                    actualHardwareFormat = hardware; isRunning = true
                    updateBackendMetrics()
                }
                return .applied
            } catch {
                let failure = AudioInputStreamCapture.operationResult(for: error)
                do {
                    try backend.stopRendering()
                    stateLock.withLock { nativeStopPending = false }
                } catch { cleanupFailure = AudioInputStreamCapture.operationResult(for: error) }
                stateLock.withLock { updateBackendMetrics() }
                return failure
            }
        }
        if let cleanupFailure { _ = emitReport(.stopOutputRenderer, cleanupFailure) }
        return emitReport(.startOutputRenderer, result)
    }

    @discardableResult
    public func stop() -> AudioStreamOperationReport {
        let result: AudioStreamOperationResult = lifecycleLock.withLock {
            let running = stateLock.withLock {
                guard isRunning || nativeStopPending else { return false }
                // Acquiring this lock waits for the preceding schedule. Close
                // before native stop can wait for an input callback to return.
                isRunning = false
                #if canImport(AVFAudio)
                conversion = OutputPCMConversion()
                #endif
                return true
            }
            guard running else { return .ignored(.alreadyStopped) }
            do {
                try backend.stopRendering()
                stateLock.withLock { nativeStopPending = false; updateBackendMetrics() }
                return .applied
            } catch { return AudioInputStreamCapture.operationResult(for: error) }
        }
        return emitReport(.stopOutputRenderer, result)
    }

    @discardableResult
    public func schedule(_ input: PCMFrame) -> AudioStreamOperationReport {
        let delivery: (AudioStreamOperationReport, PCMFrame?, ((AudioStreamRuntimeEvent) -> Void)?) = stateLock.withLock {
            guard isRunning else { return (report(.scheduleOutputFrame, .ignored(.alreadyStopped)), nil, runtimeEventHandler) }
            do {
                _ = try input.validated()
                if let limit = currentConfiguration.maximumBufferedDuration,
                   Double(input.frameCount) / input.format.sampleRate > limit {
                    throw AudioStreamError.invalidFrame("Frame exceeds live playback budget")
                }
                #if canImport(AVFAudio)
                let frame = try conversion.convert(input, to: actualHardwareFormat)
                #else
                guard input.format == actualHardwareFormat else {
                    throw AudioStreamError.hardwareFormatMismatch(expected: actualHardwareFormat, actual: input.format)
                }
                let frame = input
                #endif
                guard !frame.samples.isEmpty else { return (report(.scheduleOutputFrame, .applied), nil, runtimeEventHandler) }
                try backend.schedule(frame)
                scheduledFrameCount += 1
                updateBackendMetrics()
                return (report(.scheduleOutputFrame, .applied), frame, runtimeEventHandler)
            } catch {
                updateBackendMetrics()
                return (report(.scheduleOutputFrame, AudioInputStreamCapture.operationResult(for: error)), nil, runtimeEventHandler)
            }
        }
        delivery.2?(.operation(delivery.0))
        if let frame = delivery.1 { delivery.2?(.outputFrameScheduled(frame)) }
        return delivery.0
    }

    // Called only while state is locked and backend start/stop is not in flight.
    // Inactive callbacks read cached metrics instead of racing native teardown.
    private func updateBackendMetrics() {
        bufferedDuration = backend.bufferedOutputDuration
        playbackResets = backend.playbackResetCount
    }
    private func report(_ operation: AudioStreamOperation, _ result: AudioStreamOperationResult) -> AudioStreamOperationReport {
        .init(operation: operation, result: result, snapshot: .init(direction: .output,
            isRunning: isRunning, preferredFormat: currentConfiguration.preferredFormat,
            actualHardwareFormat: actualHardwareFormat, processedFrameCount: scheduledFrameCount,
            bufferedOutputDuration: bufferedDuration, playbackResetCount: playbackResets))
    }
    private func emitReport(_ operation: AudioStreamOperation, _ result: AudioStreamOperationResult) -> AudioStreamOperationReport {
        let delivery = stateLock.withLock { (report(operation, result), runtimeEventHandler) }
        delivery.1?(.operation(delivery.0))
        return delivery.0
    }
}

#if canImport(AVFAudio)
/// One native converter per continuous source. Never end a stream at a capture
/// block boundary: the converter retains fractional phase and filter history.
private final class OutputPCMConversion {
    private var converter: AVAudioConverter?
    private var source: AudioFormat?
    private var target: AudioFormat?
    private var inputEnd: TimeInterval?
    private var epoch: TimeInterval = 0
    private var outputFrames = 0

    func convert(_ frame: PCMFrame, to hardware: AudioFormat) throws -> PCMFrame {
        guard frame.format != hardware else {
            converter = nil; source = nil; target = nil; inputEnd = nil
            return frame
        }
        guard !frame.samples.isEmpty else { return frame }
        guard hardware.isValid else { throw AudioStreamError.invalidFrame("Invalid output hardware format") }
        let discontinuous = inputEnd.map { abs(frame.capturedAt - $0) > 2 / frame.format.sampleRate } ?? false
        if converter == nil || source != frame.format || target != hardware {
            guard let input = AVAudioFormat(audioFormat: frame.format),
                  let output = AVAudioFormat(audioFormat: hardware),
                  let native = AVAudioConverter(from: input, to: output) else {
                throw AudioStreamError.invalidFrame("Cannot create native output conversion")
            }
            native.primeMethod = .none
            converter = native; source = frame.format; target = hardware
            inputEnd = nil
        }
        if inputEnd == nil || discontinuous {
            converter?.reset()
            epoch = frame.capturedAt; outputFrames = 0
        }
        let input = try frame.makePCMBuffer()
        let required = ceil(Double(frame.frameCount) * hardware.sampleRate / frame.format.sampleRate) + 256
        guard required < Double(UInt32.max), let converter,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(required)) else {
            throw AudioStreamError.invalidFrame("Cannot allocate output conversion buffer")
        }
        var offset: AVAudioFrameCount = 0
        var nativeError: NSError?
        let status = converter.convert(to: output, error: &nativeError) { requested, state in
            guard offset < input.frameLength, requested > 0 else { state.pointee = .noDataNow; return nil }
            let count = min(requested, input.frameLength - offset)
            guard let part = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count) else {
                state.pointee = .noDataNow; return nil
            }
            part.frameLength = count
            for channel in 0..<frame.format.channelCount {
                part.floatChannelData![channel].update(from: input.floatChannelData![channel].advanced(by: Int(offset)), count: Int(count))
            }
            offset += count
            state.pointee = .haveData
            return part
        }
        guard status != .error, offset == input.frameLength,
              let result = PCMFrame(buffer: output, sequenceNumber: frame.sequenceNumber,
                  capturedAt: epoch + Double(outputFrames) / hardware.sampleRate) else {
            converter.reset(); inputEnd = nil
            throw AudioStreamError.invalidFrame("Native output conversion did not consume the complete frame")
        }
        outputFrames += result.frameCount
        inputEnd = frame.capturedAt + Double(frame.frameCount) / frame.format.sampleRate
        return result
    }
}
#endif
