import AudioCore
import AVFAudio
import Codec
import Foundation
import RTC
import SessionManager

public enum AudioDeviceError: Error, Equatable, Sendable {
    case notPrepared, stopped, endpointUnavailable, invalidAudio
}

/// One disposable encrypted audio-device pair. Async preparation is separate
/// from the existing synchronous input/output subscriptions. This backend never
/// starts an engine, mixes audio, participates in a call or schedules a clock.
public final class AudioDeviceConnection: AudioInputStreamBackend, AudioOutputStreamBackend, @unchecked Sendable {
    public let sessionID: UUID
    public let renderingEngine: AVAudioEngine?
    public let aacOptions: AACELDv2Options
    public var rendersToHardware: Bool { false }
    public var bufferedOutputDuration: TimeInterval? { 0 }
    public var playbackResetCount: Int? { 0 }
    public var unsupportedVoiceProcessingSettings: [AudioInputVoiceProcessingSetting] { [.advancedDucking] }

    private let lock = NSLock()
    private var transport: RTCAudioDeviceLink?
    private var stopped = false
    private var prepared = false
    private var endpoint: RTCAudioDeviceEndpoint?
    private var endpointWaiter: CheckedContinuation<RTCAudioDeviceEndpoint, any Error>?
    private var endpointTimeout: Task<Void, Never>?
    private var sendReady = false
    private var sendingAllowed = false
    private var captureHandler: ((PCMFrame) -> Void)?
    private var renderingFormat: AudioFormat?
    private var maximumFrameDuration: TimeInterval?
    private var encoder: StreamingCodecEncoder?
    private var decoder: StreamingCodecDecoder?
    private let availabilityHandler: @Sendable (Bool) -> Void
    private let failureHandler: @Sendable (AudioDeviceError) -> Void

    public init(sessionID: UUID, key: Data, role: RTCAudioDeviceRole,
                renderingEngine: AVAudioEngine? = nil, aacOptions: AACELDv2Options = .init(),
                onAvailability: @escaping @Sendable (Bool) -> Void = { _ in },
                onFailure: @escaping @Sendable (AudioDeviceError) -> Void = { _ in }) throws {
        self.sessionID = sessionID; self.renderingEngine = renderingEngine; self.aacOptions = aacOptions
        availabilityHandler = onAvailability; failureHandler = onFailure
        transport = try RTCAudioDeviceLink(sessionID: sessionID, key: key, role: role,
            onReceive: { [weak self] packet in self?.receive(packet) },
            onEndpointChange: { [weak self] endpoint in self?.endpointChanged(endpoint) },
            onSendAvailabilityChange: { [weak self] ready in self?.availabilityChanged(ready) },
            onFailure: { [weak self] _ in self?.fail(.endpointUnavailable) })
    }

    public var isSendReady: Bool { lock.withLock { !stopped && sendReady } }
    public var isSendingAllowed: Bool { lock.withLock { !stopped && sendingAllowed } }
    public var statistics: RTCNetworkStatistics? {
        let link = lock.withLock { transport }
        return link?.statistics
    }

    /// Publish this endpoint only through an authenticated companion channel.
    /// Endpoint publication and UDP send readiness do not prove remote playback.
    public func prepare() async throws -> RTCAudioDeviceEndpoint {
        if Task.isCancelled { stop(); throw CancellationError() }
        let link = try lock.withLock {
            guard !stopped, let transport else { throw AudioDeviceError.stopped }
            guard !Task.isCancelled else { throw CancellationError() }
            return transport
        }
        do {
            try link.start()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let ready: Result<RTCAudioDeviceEndpoint, any Error>? = lock.withLock {
                        if stopped || Task.isCancelled { return .failure(AudioDeviceError.stopped) }
                        if let endpoint { prepared = true; return .success(endpoint) }
                        guard endpointWaiter == nil else { return .failure(AudioDeviceError.endpointUnavailable) }
                        endpointWaiter = continuation
                        endpointTimeout = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(5)) } catch { return }
                            self?.fail(.endpointUnavailable)
                        }
                        return nil
                    }
                    if let ready { continuation.resume(with: ready) }
                }
            } onCancel: { self.stop() }
        } catch {
            stop()
            throw error
        }
    }

    @discardableResult public func connect(to endpoint: RTCAudioDeviceEndpoint) -> Bool {
        let link = lock.withLock { !stopped && prepared ? transport : nil }
        return link?.connect(to: endpoint) ?? false
    }

    /// Closing discards all partially encoded speech. Path recovery never
    /// reopens this gate; the owner must explicitly authorize sending again.
    public func setSendingAllowed(_ allowed: Bool) {
        lock.withLock {
            sendingAllowed = allowed && !stopped && prepared && sendReady && renderingFormat != nil
            if !sendingAllowed { encoder = nil }
        }
    }

    public func startCapture(configuration: AudioInputStreamConfiguration,
                             onFrame: @escaping (PCMFrame) -> Void) throws -> AudioFormat {
        try lock.withLock {
            try requirePrepared()
            captureHandler = onFrame
            decoder = StreamingCodecDecoder()
            return configuration.preferredFormat
        }
    }

    public func stopCapture() throws {
        lock.withLock { captureHandler = nil; decoder = nil }
    }

    public func updateVoiceProcessing(_ configuration: AudioInputVoiceProcessingConfiguration) throws {
        // SessionManager owns the software input-mute boundary. Device media
        // adds no second VAD, effects graph or hardware voice processor.
        throw AudioStreamError.unsupportedOnCurrentPlatform
    }

    public func startRendering(configuration: AudioOutputStreamConfiguration) throws -> AudioFormat {
        try lock.withLock {
            try requirePrepared()
            guard configuration.preferredFormat.isValid,
                  configuration.maximumBufferedDuration.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw AudioStreamError.invalidFrame("Invalid audio-device output format or budget")
            }
            // The caller chooses the source's actual format where possible.
            // AudioOutputStreamRenderer converts only when its input differs.
            // Reject an unsupported native format/bitrate at setup, rather
            // than silently changing channels, rate or codec on first speech.
            let replacement = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD,
                format: configuration.preferredFormat, aacELDv2Options: aacOptions), suppressesSilence: true)
            renderingFormat = configuration.preferredFormat
            maximumFrameDuration = configuration.maximumBufferedDuration
            encoder = replacement
            return configuration.preferredFormat
        }
    }

    public func stopRendering() throws {
        lock.withLock { renderingFormat = nil; encoder = nil; sendingAllowed = false }
    }

    public func schedule(_ frame: PCMFrame) throws {
        _ = try frame.validated()
        let requested = ContinuousClock.now
        let output: (RTCAudioDeviceLink?, RTCAudioPacket?)
        do {
            output = try lock.withLock {
                try requirePrepared()
                guard let format = renderingFormat else { throw AudioDeviceError.notPrepared }
                guard frame.format == format else {
                    throw AudioStreamError.hardwareFormatMismatch(expected: format, actual: frame.format)
                }
                if let limit = maximumFrameDuration, Double(frame.frameCount) / frame.format.sampleRate > limit {
                    throw AudioStreamError.invalidFrame("Frame exceeds audio-device output budget")
                }
                guard sendingAllowed, sendReady, requested.duration(to: .now) < .milliseconds(100) else { return (nil, nil) }
                if encoder == nil {
                    encoder = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD, format: format, aacELDv2Options: aacOptions), suppressesSilence: true)
                }
                guard let value = try encoder?.encode(frame) else { return (nil, nil) }
                let packet = RTCAudioPacket(sequenceNumber: value.sequenceNumber,
                    codec: .init(rawValue: value.codec.rawValue),
                    format: .init(sampleRate: value.format.sampleRate, channelCount: value.format.channelCount),
                    capturedAt: value.capturedAt, sampleCount: value.sampleCount, bitRate: value.bitRate, payload: value.payload)
                return (transport, packet)
            }
        } catch let error as AudioStreamError { throw error }
        catch let error as AudioDeviceError { throw error }
        catch {
            fail(.invalidAudio)
            throw AudioStreamError.invalidFrame("Audio-device encoding failed: \(error)")
        }
        // Transport callbacks enter our lock. All native transport calls and
        // user callbacks must remain outside it, including stop and failures.
        if requested.duration(to: .now) < .milliseconds(100), let packet = output.1 { _ = output.0?.send(packet) }
        else if output.1 != nil { lock.withLock { encoder = nil } }
    }

    public func stop() {
        let state = lock.withLock { () -> (RTCAudioDeviceLink?, CheckedContinuation<RTCAudioDeviceEndpoint, any Error>?) in
            guard !stopped else { return (nil, nil) }
            stopped = true; prepared = false; sendReady = false; sendingAllowed = false
            encoder = nil; decoder = nil; captureHandler = nil; renderingFormat = nil
            let state = (transport, endpointWaiter)
            transport = nil; endpoint = nil; endpointWaiter = nil
            endpointTimeout?.cancel(); endpointTimeout = nil
            return state
        }
        state.1?.resume(throwing: AudioDeviceError.stopped)
        state.0?.stop()
    }

    private func requirePrepared() throws {
        guard !stopped else { throw AudioDeviceError.stopped }
        guard prepared else { throw AudioDeviceError.notPrepared }
    }

    private func endpointChanged(_ endpoint: RTCAudioDeviceEndpoint?) {
        guard let endpoint else { return }
        let waiter = lock.withLock { () -> CheckedContinuation<RTCAudioDeviceEndpoint, any Error>? in
            guard !stopped else { return nil }
            self.endpoint = endpoint
            let waiter = endpointWaiter; endpointWaiter = nil
            if waiter != nil { prepared = true }
            endpointTimeout?.cancel(); endpointTimeout = nil
            return waiter
        }
        waiter?.resume(returning: endpoint)
    }

    func availabilityChanged(_ ready: Bool) {
        let deliver = lock.withLock {
            guard !stopped else { return false }
            sendReady = ready
            if !ready { sendingAllowed = false; encoder = nil }
            return true
        }
        if deliver { availabilityHandler(ready) }
    }

    func receive(_ packet: RTCAudioPacket) {
        do {
            let delivery: (PCMFrame, (PCMFrame) -> Void)? = try lock.withLock {
                guard !stopped, let captureHandler, let decoder else { return nil }
                guard packet.codec.rawValue == CodecIdentifier.mpeg4AACELD.rawValue, let count = packet.sampleCount else {
                    throw AudioDeviceError.invalidAudio
                }
                let frame = try decoder.decode(.init(sequenceNumber: packet.sequenceNumber, codec: .mpeg4AACELD,
                    format: .init(sampleRate: packet.format.sampleRate, channelCount: packet.format.channelCount),
                    capturedAt: packet.capturedAt, sampleCount: count, bitRate: packet.bitRate, payload: packet.payload))
                return (frame, captureHandler)
            }
            if let delivery, !delivery.0.samples.isEmpty { delivery.1(delivery.0) }
        } catch { fail(.invalidAudio) }
    }

    private func fail(_ error: AudioDeviceError) {
        let deliver = lock.withLock { !stopped }
        stop()
        if deliver { failureHandler(error) }
    }

    deinit { transport?.stop(); endpointTimeout?.cancel() }
}
