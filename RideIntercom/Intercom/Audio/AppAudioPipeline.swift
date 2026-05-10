import AudioCore
import AudioMixer
import Codec
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

    init(
        mixerFormat: AudioFormat = .intercomMixer,
        rtcSendFormat: AudioFormat = .intercomPacketAudio,
        outputHardwareFormat: AudioFormat = .intercomHardwarePreferred,
        preferredCodec: AudioCodecIdentifier = .pcm16,
        aacELDv2BitRate: Int = 32_000,
        opusBitRate: Int = 32_000,
        masterOutputVolume: Float = 1,
        isOutputMuted: Bool = false,
        peerOutputVolumes: [String: Float] = [:]
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
}

final class AppAudioPipeline {
    private static let silenceThreshold: Float = 0.000_001

    var onTransmitPacket: ((RTC.RTCAudioPacket) -> Void)?
    var onOutputFrame: ((PCMFrame) -> Void)?

    private var configuration = AppAudioPipelineConfiguration()
    private var mixer: AudioMixer?
    private var txSource: MixerPCMSource?
    private var rxMasterBus: MixerBus?
    private var rxSourcesByPeerID: [String: MixerPCMSource] = [:]

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
        mixer?.stop()
        self.configuration = configuration
        rxSourcesByPeerID.removeAll()

        let mixer = try AudioMixer(audioFormat: configuration.mixerFormat)
        let txBus = try mixer.createBus("tx-bus")
        let txSource = try txBus.addPCMSource(id: "microphone-input")
        _ = try txBus.installPCMSink(
            id: "rtc-send",
            targetFormat: configuration.rtcSendFormat
        ) { [weak self] frame, _ in
            self?.encodeAndPublish(frame)
        }

        let rxMasterBus = try mixer.createBus("rx-master")
        rxMasterBus.volume = configuration.isOutputMuted ? 0 : configuration.masterOutputVolume
        _ = try rxMasterBus.installPCMSink(
            id: "speaker-output",
            targetFormat: configuration.outputHardwareFormat
        ) { [weak self] frame, _ in
            self?.publishOutput(frame)
        }
        let engineOutputBus = try mixer.createBus("engine-output")
        engineOutputBus.volume = 0
        try mixer.route(txBus, to: engineOutputBus)
        try mixer.route(rxMasterBus, to: engineOutputBus)
        try mixer.routeToOutput(engineOutputBus)

        self.mixer = mixer
        self.txSource = txSource
        self.rxMasterBus = rxMasterBus

        for peerID in peerIDs {
            _ = try ensureReceivePeer(peerID)
        }

        try mixer.start()
        txSource.start()
        rxSourcesByPeerID.values.forEach { $0.start() }
    }

    func stop() {
        mixer?.stop()
        mixer = nil
        txSource = nil
        rxMasterBus = nil
        rxSourcesByPeerID.removeAll()
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
        source.start()
        return frame
    }

    private func ensureReceivePeer(_ peerID: String) throws -> MixerPCMSource {
        if let source = rxSourcesByPeerID[peerID] {
            return source
        }
        guard let mixer, let rxMasterBus else { throw AppAudioPipelineError.notConfigured }
        let peerBus = try mixer.createBus("rx-peer-\(peerID)")
        let source = try peerBus.addPCMSource(id: "rtc-audio-\(peerID)")
        source.volume = configuration.peerOutputVolumes[peerID] ?? 1
        try mixer.route(peerBus, to: rxMasterBus)
        rxSourcesByPeerID[peerID] = source
        return source
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
