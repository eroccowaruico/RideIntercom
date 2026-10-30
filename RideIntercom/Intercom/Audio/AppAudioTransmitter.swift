import AVFAudio
import AudioCore
import AudioMixer
import Codec
import DynamicsProcessor
import Foundation
import PeakLimiter
import RTC
import SoundIsolation
import VADGate

nonisolated struct AudioInputObservation: Sendable {
    var level: Float = 0
    var voiceActive = false
    var sentPackets = 0
    var failure: String?
}

/// Capture, VAD, DSP and encoding share one synchronous owner. The package
/// capture worker calls it directly; UI reads snapshots and applies settings.
nonisolated final class AppAudioTransmitter: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var processor: AudioFrameProcessor?
    private var encoder: StreamingCodecEncoder?
    private var encoding = CodecEncodingConfiguration()
    private struct EncodingTransition {
        var configuration: CodecEncodingConfiguration
        var drainThrough: TimeInterval?
    }
    private var encodingTransition: EncodingTransition?
    private var isolation: VoiceIsolationEffect?
    private var dynamics: DynamicsProcessorEffect?
    private var limiter: PeakLimiterEffect?
    private var controller = AudioTransmissionController()
    private var pendingPackets: [RTCAudioPacket] = []
    private var sequence: UInt64 = 0
    private var failures = 0
    private var muted = false
    private var observation = AudioInputObservation()
    private var packetHandler: (@Sendable (RTCAudioPacket) -> Void)?

    var onPacket: (@Sendable (RTCAudioPacket) -> Void)? {
        get { lock.withLock { packetHandler } }
        set { lock.withLock { packetHandler = newValue } }
    }
    var inputObservation: AudioInputObservation { lock.withLock { observation } }
    var failureCount: Int { lock.withLock { failures } }
    var snapshot: AudioMixerSnapshot? { lock.withLock { processor?.mixer.snapshot() } }
    var isolationSnapshot: VoiceIsolationRuntimeSnapshot? { lock.withLock { isolation?.runtimeSnapshot } }
    var dynamicsSnapshot: DynamicsProcessorRuntimeSnapshot? { lock.withLock { dynamics?.runtimeSnapshot } }
    var limiterSnapshot: PeakLimiterRuntimeSnapshot? { lock.withLock { limiter?.runtimeSnapshot } }
    var vadSnapshot: VADGateRuntimeSnapshot { lock.withLock { controller.runtimeSnapshot } }
    func setController(_ value: AudioTransmissionController) { lock.withLock { controller = value } }
    func setMuted(_ value: Bool) {
        lock.withLock {
            guard muted != value else { return }
            muted = value
            controller.reset()
            encoder = nil
            pendingPackets.removeAll(keepingCapacity: true)
            observation.level = 0; observation.voiceActive = false
        }
    }
    func applyVADSensitivity(_ value: VoiceActivitySensitivity) { lock.withLock { controller.applyVADSensitivity(value) } }

    func rebuild(configuration: AppAudioPipelineConfiguration, encoding: CodecEncodingConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        stop()
        self.encoding = encoding
        let processor = try AudioFrameProcessor(format: configuration.mixerFormat,
            outputFormat: configuration.rtcSendFormat, busID: "tx-bus", suspendsDuringSilence: true) { [weak self] frame, _ in
                self?.encodeAndCollect(frame)
            }
        self.processor = processor
        isolation = try AppAudioPipeline.makeIsolation(on: processor.bus, enabled: configuration.transmitSoundIsolationEnabled)
        let dynamics = try DynamicsProcessorEffect.make()
        try processor.bus.addEffect(dynamics.node, id: "dynamics-processor", state: .active,
            parameters: AppAudioPipeline.effectParameters(package: "DynamicsProcessor", label: "Dynamics",
                detail: "Threshold \(dynamics.configuration.threshold) dB"))
        self.dynamics = dynamics
        limiter = try AppAudioPipeline.installLimiter(on: processor.bus)
        try processor.start()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        processor?.stop(); processor = nil; encoder = nil; encodingTransition = nil; pendingPackets.removeAll()
        controller.reset()
        observation.level = 0; observation.voiceActive = false
        isolation = nil; dynamics = nil; limiter = nil
    }

    func updateEncoding(_ configuration: CodecEncodingConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        try requestEncoding(configuration)
    }

    private func requestEncoding(_ configuration: CodecEncodingConfiguration) throws {
        guard configuration.format.isValid else { throw AppAudioPipelineError.invalidFormat }
        guard configuration != (encodingTransition?.configuration ?? encoding) else { return }
        if encoder == nil || muted || configuration == encoding {
            try processor?.updateOutputFormat(configuration.format)
            encoding = configuration
            if encodingTransition != nil { processor?.bus.beginSinkTransition(settlingDuration: 0) }
            encodingTransition = nil
            return
        }
        // Finish a short old-format fade before a new codec can need its first
        // native packet. Only replaceable settings coalesce; normal capture and
        // transmission keep their cadence and never wait on a timer or network.
        if encodingTransition == nil {
            processor?.bus.beginSinkTransition(settlingDuration: 0, holding: true)
            encodingTransition = .init(configuration: configuration)
        } else { encodingTransition?.configuration = configuration }
    }

    private func processFrame(_ frame: PCMFrame) throws {
        if encodingTransition != nil, encodingTransition?.drainThrough == nil {
            encodingTransition?.drainThrough = frame.capturedAt + 0.002 + (encoder?.transitionDrainDuration ?? 0)
        }
        try processor?.process(frame)
        guard let change = encodingTransition, let end = change.drainThrough else { return }
        let sentThrough = pendingPackets.last.flatMap { packet in
            packet.sampleCount.map { packet.capturedAt + Double($0 / packet.format.channelCount) / packet.format.sampleRate }
        }
        let silentAndDrained = frame.samples.allSatisfy { $0 == 0 }
            && frame.capturedAt + Double(frame.frameCount) / frame.format.sampleRate >= end + 0.01
        guard sentThrough.map({ $0 >= end }) == true || silentAndDrained else { return }
        try processor?.updateOutputFormat(change.configuration.format)
        encoding = change.configuration
        encoder = nil
        encodingTransition = nil
        processor?.bus.beginSinkTransition(settlingDuration: 0)
    }

    func updateIsolation(enabled: Bool) throws {
        // Settings/lifecycle share their serial owner. Prepare the disconnected
        // unit before taking the capture lock so the current stream keeps moving.
        let preparation = lock.withLock {
            enabled && isolation?.avAudioUnitEffect.bypass == true ? processor?.bus : nil
        }
        try preparation?.prepareEffect(id: "sound-isolation")
        lock.lock(); defer { lock.unlock() }
        guard let effect = isolation, let bus = processor?.bus,
              effect.avAudioUnitEffect.bypass != !enabled else { return }
        try effect.apply(AppAudioPipeline.isolationConfiguration(enabled: enabled))
        effect.avAudioUnitEffect.bypass = !enabled
        try bus.setEffectBypassed(id: "sound-isolation", bypassed: !enabled)
        try bus.updateEffectSnapshot(id: "sound-isolation", state: enabled ? .active : .bypassed)
        bus.beginSinkTransition(settlingDuration: bus.processingLatency)
    }

    func processMicrophone(_ frame: PCMFrame, level: Float? = nil, shouldProcess: @Sendable () -> Bool = { true }) {
        lock.lock()
        guard shouldProcess(), processor != nil else {
            observation.level = 0; observation.voiceActive = false; lock.unlock(); return
        }
        let level = muted ? 0 : level ?? (try? AudioSignalMeter.measure(frame).rms) ?? 0
        observation.level = level
        var input = frame
        if muted { input.samples = Array(repeating: 0, count: frame.samples.count) }
        // The package drains native tails before sleeping through mute/silence.
        let packets: [OutboundAudioPacket] = muted ? [.silence(input)] : controller.process(frame: input, level: level)
        observation.voiceActive = packets.contains { if case .voice = $0 { return true }; return false }
        observation.failure = nil
        for packet in packets {
            switch packet {
            case .voice(let pcm), .silence(let pcm):
                do { try processFrame(pcm) }
                catch { failures += 1; observation.failure = String(describing: type(of: error)) }
            }
        }
        let packetsToSend = pendingPackets, handler = packetHandler
        pendingPackets.removeAll(keepingCapacity: true)
        lock.unlock()
        for packet in packetsToSend { handler?(packet) }
    }

    func process(_ frame: PCMFrame) throws {
        let delivery = try lock.withLock {
            guard processor != nil else { throw AppAudioPipelineError.notConfigured }
            defer { pendingPackets.removeAll(keepingCapacity: true) }
            try processFrame(frame)
            return (pendingPackets, packetHandler)
        }
        for packet in delivery.0 { delivery.1?(packet) }
    }

    private func encodeAndCollect(_ frame: PCMFrame) {
        guard !muted else { return }
        do {
            if encoder?.configuration != encoding {
                encoder = try StreamingCodecEncoder(configuration: encoding, suppressesSilence: true)
            }
            guard let encoded = try encoder?.encode(frame) else { return }
            let packet = RTCAudioPacket(sequenceNumber: sequence, codec: .init(rawValue: encoded.codec.rawValue),
                format: .init(sampleRate: encoded.format.sampleRate, channelCount: encoded.format.channelCount),
                capturedAt: encoded.capturedAt, sampleCount: encoded.sampleCount,
                bitRate: encoded.bitRate, payload: encoded.payload)
            sequence &+= 1
            observation.sentPackets += 1
            pendingPackets.append(packet)
        } catch { failures += 1; encoder = nil }
    }

    deinit { processor?.stop() }
}
