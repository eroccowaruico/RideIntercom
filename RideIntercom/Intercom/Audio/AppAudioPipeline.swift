import AVFAudio
import AudioCore
import AudioMixer
import Codec
import DynamicsProcessor
import PeakLimiter
import SoundIsolation
import Foundation
import RTC

struct AppAudioPipelineConfiguration: Equatable {
    var mixerFormat: AudioFormat
    var rtcSendFormat: AudioFormat
    var outputHardwareFormat: AudioFormat
    var preferredCodec: AudioCodecIdentifier
    var aacELDv2BitRate: Int
    var opusBitRate: Int
    var masterOutputVolume: Float
    var isOutputMuted: Bool
    var peerOutputVolumes: [String: Float]
    var transmitSoundIsolationEnabled: Bool
    var receiveMasterSoundIsolationEnabled: Bool
    var peerSoundIsolationEnabled: [String: Bool]
    var maximumBufferedDuration: TimeInterval?

    init(
        mixerFormat: AudioFormat = .intercomMixer,
        rtcSendFormat: AudioFormat = .intercomPacketAudio,
        outputHardwareFormat: AudioFormat = .intercomHardwarePreferred,
        preferredCodec: AudioCodecIdentifier = .pcm16,
        aacELDv2BitRate: Int = 32_000,
        opusBitRate: Int = 32_000,
        masterOutputVolume: Float = 1,
        isOutputMuted: Bool = false,
        peerOutputVolumes: [String: Float] = [:],
        transmitSoundIsolationEnabled: Bool = true,
        receiveMasterSoundIsolationEnabled: Bool = false,
        peerSoundIsolationEnabled: [String: Bool] = [:],
        maximumBufferedDuration: TimeInterval? = nil
    ) {
        self.mixerFormat = mixerFormat
        self.rtcSendFormat = rtcSendFormat
        self.outputHardwareFormat = outputHardwareFormat
        self.preferredCodec = preferredCodec
        self.aacELDv2BitRate = Codec.AACELDv2Options(bitRate: aacELDv2BitRate).bitRate
        self.opusBitRate = Codec.OpusOptions(bitRate: opusBitRate).bitRate
        self.masterOutputVolume = min(2, max(0, masterOutputVolume))
        self.isOutputMuted = isOutputMuted
        self.peerOutputVolumes = peerOutputVolumes.mapValues { min(1, max(0, $0)) }
        self.transmitSoundIsolationEnabled = transmitSoundIsolationEnabled
        self.receiveMasterSoundIsolationEnabled = receiveMasterSoundIsolationEnabled
        self.peerSoundIsolationEnabled = peerSoundIsolationEnabled
        self.maximumBufferedDuration = maximumBufferedDuration
    }

    var codecOptions: AppAudioCodecOptions {
        AppAudioCodecOptions(aacELDv2BitRate: aacELDv2BitRate, opusBitRate: opusBitRate)
    }

    var audioPolicy: RTC.RTCAudioPolicy {
        AppAudioCodecBridge.makeRTCAudioPolicy(
            preferred: preferredCodec,
            format: rtcSendFormat,
            options: codecOptions
        )
    }

    var codecRuntimeReport: CodecRuntimeReport {
        AppAudioCodecBridge.runtimeReport(
            for: preferredCodec,
            format: rtcSendFormat,
            options: codecOptions
        )
    }
}

enum AppAudioPipelineError: Error, Equatable {
    case notConfigured
    case invalidFormat
}

final class AppAudioPipeline {
    private static let silenceThreshold: Float = 0.000_001

    var onTransmitPacket: ((RTC.RTCAudioPacket) -> Void)?
    var onOutputFrame: ((PCMFrame) -> Void)?

    private let makeEngine: () -> AVAudioEngine
    private var generation = UUID()
    private var frameDeliveries: [AudioFrameDelivery] = []

    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() }) {
        self.makeEngine = makeEngine
    }

    deinit { mixer?.stop() }

    private var configuration = AppAudioPipelineConfiguration()
    private var mixer: AudioMixer?
    private var txSource: MixerPCMSource?
    private var rxMasterBus: MixerBus?
    private var rxSourcesByPeerID: [String: MixerPCMSource] = [:]

    private var isolationEffects: [String: VoiceIsolationEffect] = [:]
    private var transmitDynamics: DynamicsProcessorEffect?
    private var transmitLimiter: PeakLimiterEffect?
    private var outputLimiter: PeakLimiterEffect?

    var isolationRuntimeSnapshots: [String: VoiceIsolationRuntimeSnapshot] {
        isolationEffects.mapValues(\.runtimeSnapshot)
    }
    var dynamicsRuntimeSnapshot: DynamicsProcessorRuntimeSnapshot? { transmitDynamics?.runtimeSnapshot }
    var transmitLimiterRuntimeSnapshot: PeakLimiterRuntimeSnapshot? { transmitLimiter?.runtimeSnapshot }
    var outputLimiterRuntimeSnapshot: PeakLimiterRuntimeSnapshot? { outputLimiter?.runtimeSnapshot }

    var snapshot: AudioMixerSnapshot {
        mixer?.snapshot() ?? AudioMixerSnapshot(busIDs: [], buses: [], routes: [], outputBusID: nil)
    }

    var codecRuntimeReport: CodecRuntimeReport {
        configuration.codecRuntimeReport
    }

    var audioPolicy: RTC.RTCAudioPolicy {
        configuration.audioPolicy
    }

    func rebuild(configuration: AppAudioPipelineConfiguration, peerIDs: [String]) throws {
        stop()
        var completed = false
        defer { if !completed { stop() } }
        guard configuration.mixerFormat.sampleRate > 0, configuration.mixerFormat.channelCount > 0 else {
            throw AppAudioPipelineError.invalidFormat
        }
        let generation = self.generation
        self.configuration = configuration
        rxSourcesByPeerID.removeAll()

        let mixer = try AudioMixer(engine: makeEngine(), audioFormat: configuration.mixerFormat)
        self.mixer = mixer
        let txBus = try mixer.createBus("tx-bus")
        try installIsolation(on: txBus, enabled: configuration.transmitSoundIsolationEnabled)
        let dynamics = try DynamicsProcessorEffect.make()
        try txBus.addEffect(dynamics.node, id: "dynamics-processor", state: .active,
            parameters: Self.effectParameters(package: "DynamicsProcessor", label: "Dynamics", detail: "Threshold \(dynamics.configuration.threshold) dB"))
        transmitDynamics = dynamics
        transmitLimiter = try installLimiter(on: txBus)
        let txSource = try txBus.addPCMSource(id: "microphone-input", maximumBufferedDuration: configuration.maximumBufferedDuration)
        let transmitDelivery = AudioFrameDelivery { [weak self] frame in
            guard let self, self.generation == generation else { return }
            self.encodeAndPublish(frame)
        }
        frameDeliveries.append(transmitDelivery)
        _ = try txBus.installPCMSink(
            id: "rtc-send",
            targetFormat: configuration.rtcSendFormat
        ) { frame, _ in transmitDelivery.yield(frame) }

        let rxMasterBus = try mixer.createBus("rx-master")
        rxMasterBus.volume = configuration.isOutputMuted ? 0 : configuration.masterOutputVolume
        try installIsolation(on: rxMasterBus, enabled: configuration.receiveMasterSoundIsolationEnabled)
        // The final limiter must follow master gain; Mixer effects precede each bus fader.
        let rxOutputBus = try mixer.createBus("rx-output")
        outputLimiter = try installLimiter(on: rxOutputBus)
        try mixer.route(rxMasterBus, to: rxOutputBus)
        let outputDelivery = AudioFrameDelivery { [weak self] frame in
            guard let self, self.generation == generation else { return }
            self.publishOutput(frame)
        }
        frameDeliveries.append(outputDelivery)
        _ = try rxOutputBus.installPCMSink(
            id: "speaker-output",
            targetFormat: configuration.outputHardwareFormat
        ) { frame, _ in outputDelivery.yield(frame) }
        let engineOutputBus = try mixer.createBus("engine-output")
        engineOutputBus.volume = 0
        try mixer.route(txBus, to: engineOutputBus)
        try mixer.route(rxOutputBus, to: engineOutputBus)
        try mixer.routeToOutput(engineOutputBus)

        self.txSource = txSource
        self.rxMasterBus = rxMasterBus

        for peerID in peerIDs {
            _ = try ensureReceivePeer(peerID)
        }

        try mixer.start()
        txSource.start()
        rxSourcesByPeerID.values.forEach { $0.start() }
        completed = true
    }

    func stop() {
        generation = UUID()
        frameDeliveries.forEach { $0.finish() }
        frameDeliveries.removeAll()
        mixer?.stop()
        mixer = nil
        txSource = nil
        rxMasterBus = nil
        rxSourcesByPeerID.removeAll()
        isolationEffects.removeAll()
        transmitDynamics = nil
        transmitLimiter = nil
        outputLimiter = nil
    }

    func updateOutput(masterVolume: Float, isMuted: Bool, peerOutputVolumes: [String: Float]) {
        configuration.masterOutputVolume = min(2, max(0, masterVolume))
        configuration.isOutputMuted = isMuted
        configuration.peerOutputVolumes = peerOutputVolumes.mapValues { min(1, max(0, $0)) }
        rxMasterBus?.volume = configuration.isOutputMuted ? 0 : configuration.masterOutputVolume
        for (peerID, source) in rxSourcesByPeerID {
            source.volume = configuration.peerOutputVolumes[peerID] ?? 1
        }
    }

    func processCapturedFrame(_ frame: PCMFrame) throws {
        guard let txSource else { throw AppAudioPipelineError.notConfigured }
        _ = try txSource.schedule(frame)
    }

    @discardableResult
    func processReceivedAudioPacket(_ received: RTC.ReceivedAudioPacket) throws -> PCMFrame {
        let frame = try AppAudioCodecBridge.decode(received.packet)
        let source = try ensureReceivePeer(received.peerID.rawValue)
        _ = try source.schedule(frame)
        if !source.playerNode.isPlaying { source.start() }
        return frame
    }

    func processPlaybackFrame(_ frame: PCMFrame) throws {
        let source = try ensureReceivePeer("audio-check")
        _ = try source.schedule(frame)
        if !source.playerNode.isPlaying { source.start() }
    }

    func stopReceivePeer(_ peerID: String) throws {
        guard rxSourcesByPeerID.removeValue(forKey: peerID) != nil else { return }
        try mixer?.removeBus("rx-peer-\(peerID)")
        isolationEffects.removeValue(forKey: "rx-peer-\(peerID)")
    }

    private func ensureReceivePeer(_ peerID: String) throws -> MixerPCMSource {
        if let source = rxSourcesByPeerID[peerID] {
            return source
        }
        guard let mixer, let rxMasterBus else { throw AppAudioPipelineError.notConfigured }
        let peerBus = try mixer.createBus("rx-peer-\(peerID)")
        try installIsolation(on: peerBus, enabled: configuration.peerSoundIsolationEnabled[peerID] ?? false)
        let source = try peerBus.addPCMSource(id: "rtc-audio-\(peerID)", maximumBufferedDuration: configuration.maximumBufferedDuration)
        source.volume = configuration.peerOutputVolumes[peerID] ?? 1
        try mixer.route(peerBus, to: rxMasterBus)
        rxSourcesByPeerID[peerID] = source
        if mixer.engine.isRunning { source.start() }
        return source
    }

    func updateSoundIsolation(transmit: Bool, receiveMaster: Bool, peers: [String: Bool]) throws {
        configuration.transmitSoundIsolationEnabled = transmit
        configuration.receiveMasterSoundIsolationEnabled = receiveMaster
        configuration.peerSoundIsolationEnabled = peers
        for (busID, effect) in isolationEffects {
            let enabled: Bool
            switch busID {
            case "tx-bus": enabled = transmit
            case "rx-master": enabled = receiveMaster
            default: enabled = peers[String(busID.dropFirst("rx-peer-".count))] ?? false
            }
            effect.avAudioUnitEffect.bypass = !enabled
            guard let bus = mixer?.bus(busID) else { throw AppAudioPipelineError.notConfigured }
            try bus.updateEffectSnapshot(id: "sound-isolation",
                state: effect.runtimeSnapshot.state == .bypassed ? .bypassed : .active)
        }
    }

    private func installIsolation(on bus: MixerBus, enabled: Bool) throws {
        guard VoiceIsolationSupport.isAvailable else { return }
        let effect = try VoiceIsolationEffect.make()
        effect.avAudioUnitEffect.bypass = !enabled
        try bus.addEffect(effect.node, id: "sound-isolation", state: enabled ? .active : .bypassed,
            parameters: Self.effectParameters(package: "SoundIsolation", label: "Isolation", detail: effect.configuration.soundType.rawValue))
        isolationEffects[bus.id] = effect
    }

    private func installLimiter(on bus: MixerBus) throws -> PeakLimiterEffect {
        let effect = try PeakLimiterEffect.make()
        try bus.addEffect(effect.node, id: "peak-limiter", state: .active,
            parameters: Self.effectParameters(package: "PeakLimiter", label: "Limiter", detail: "Pre-gain \(effect.configuration.preGain) dB"))
        return effect
    }

    private static func effectParameters(package: String, label: String, detail: String) -> [MixerEffectParameterSnapshot] {
        [.init(id: "package", value: package), .init(id: "name", value: label),
         .init(id: "shortLabel", value: label), .init(id: "detail", value: detail)]
    }

    private func encodeAndPublish(_ frame: PCMFrame) {
        guard Self.containsSignal(frame) else { return }
        guard let packet = try? AppAudioCodecBridge.encode(
            frame,
            preferred: configuration.preferredCodec,
            options: configuration.codecOptions
        ) else { return }
        onTransmitPacket?(packet)
    }

    private func publishOutput(_ frame: PCMFrame) {
        guard Self.containsSignal(frame) else { return }
        onOutputFrame?(frame)
    }

    private static func containsSignal(_ frame: PCMFrame) -> Bool {
        frame.samples.contains { abs($0) > silenceThreshold }
    }
}
