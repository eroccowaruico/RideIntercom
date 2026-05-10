import AVFAudio
import AudioCore
import AudioMixer
import Codec
import DynamicsProcessor
import Foundation
import PeakLimiter
import RTC
import SessionManager
import SoundIsolation
import VADGate

extension IntercomViewModel {
    static func emptyAudioMixerSnapshot() -> AudioMixerSnapshot {
        AudioMixerSnapshot(busIDs: [], buses: [], routes: [], outputBusID: nil)
    }

    static func makeCodecRuntimeReport(
        preferredCodec: AudioCodecIdentifier,
        rtcSendFormat: AudioFormat = .intercomPacketAudio,
        aacELDv2BitRate: Int,
        opusBitRate: Int
    ) -> CodecRuntimeReport {
        AppAudioCodecBridge.runtimeReport(
            for: preferredCodec,
            format: rtcSendFormat,
            options: AppAudioCodecOptions(
                aacELDv2BitRate: aacELDv2BitRate,
                opusBitRate: opusBitRate
            )
        )
    }

    func refreshPackageRuntimeSnapshots(now: TimeInterval = Date().timeIntervalSince1970) {
        codecRuntimeReport = Self.makeCodecRuntimeReport(
            preferredCodec: preferredTransmitCodec,
            rtcSendFormat: rtcAudioFormatPreset.audioFormat,
            aacELDv2BitRate: aacELDv2BitRate,
            opusBitRate: opusBitRate
        )
        vadGateRuntimeSnapshot = audioTransmissionController.runtimeSnapshot
        audioMixerSnapshot = makeAudioMixerSnapshot()
        lastRuntimePackageReports = makeRuntimePackageReports(generatedAt: now)
    }

    func publishRuntimePackageReports(
        force: Bool = false,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        if !force,
           let lastRuntimePackageReportPublishedAt,
           now - lastRuntimePackageReportPublishedAt < Self.runtimePackageReportPublishInterval {
            return
        }
        refreshPackageRuntimeSnapshots(now: now)
        lastRuntimePackageReportPublishedAt = now
        callSession.updateRuntimePackageReports(lastRuntimePackageReports)
    }

    func mixerBusSnapshot(id: String) -> MixerBusSnapshot? {
        audioMixerSnapshot.buses.first { $0.id == id }
    }

    func makeRuntimePackageReports(generatedAt: TimeInterval) -> [RTCRuntimePackageReport] {
        var reports: [RTCRuntimePackageReport] = []
        appendReport(&reports, package: "AudioMixer", kind: "snapshot", generatedAt: generatedAt, payload: audioMixerSnapshot)
        appendReport(&reports, package: "Codec", kind: "runtimeReport", generatedAt: generatedAt, payload: codecRuntimeReport)
        appendReport(&reports, package: "VADGate", kind: "runtimeSnapshot", generatedAt: generatedAt, payload: vadGateRuntimeSnapshot)
        appendReport(&reports, package: "SoundIsolation", kind: "transmitRuntimeSnapshot", generatedAt: generatedAt, payload: makeVoiceIsolationRuntimeSnapshot(enabled: isSoundIsolationEnabled))
        appendReport(&reports, package: "SoundIsolation", kind: "receiveMasterRuntimeSnapshot", generatedAt: generatedAt, payload: makeVoiceIsolationRuntimeSnapshot(enabled: receiveMasterSoundIsolationEnabled))
        appendReport(&reports, package: "DynamicsProcessor", kind: "transmitRuntimeSnapshot", generatedAt: generatedAt, payload: makeDynamicsProcessorRuntimeSnapshot())
        appendReport(&reports, package: "PeakLimiter", kind: "transmitRuntimeSnapshot", generatedAt: generatedAt, payload: makePeakLimiterRuntimeSnapshot())
        appendReport(&reports, package: "PeakLimiter", kind: "receiveMasterRuntimeSnapshot", generatedAt: generatedAt, payload: makePeakLimiterRuntimeSnapshot())
        appendReport(&reports, package: "SessionManager", kind: "audioSessionConfigurationRequest", generatedAt: generatedAt, payload: makeAudioSessionConfiguration())
        if let lastAudioSessionConfigurationReport {
            appendReport(&reports, package: "SessionManager", kind: "audioSessionConfigurationReport", generatedAt: generatedAt, payload: lastAudioSessionConfigurationReport)
        }
        if let lastInputStreamOperationReport {
            appendReport(&reports, package: "SessionManager", kind: "inputStreamOperationReport", generatedAt: generatedAt, payload: lastInputStreamOperationReport)
        }
        if let lastOutputStreamOperationReport {
            appendReport(&reports, package: "SessionManager", kind: "outputStreamOperationReport", generatedAt: generatedAt, payload: lastOutputStreamOperationReport)
        }
        if let lastVoiceProcessingOperationReport {
            appendReport(&reports, package: "SessionManager", kind: "voiceProcessingOperationReport", generatedAt: generatedAt, payload: lastVoiceProcessingOperationReport)
        }
        return reports
    }

    private func appendReport<Payload: Encodable>(
        _ reports: inout [RTCRuntimePackageReport],
        package: String,
        kind: String,
        generatedAt: TimeInterval,
        payload: Payload
    ) {
        guard let report = try? RTCRuntimePackageReport.json(
            package: package,
            kind: kind,
            generatedAt: generatedAt,
            payload: payload
        ) else {
            return
        }
        reports.append(report)
    }

    private func makeAudioMixerSnapshot() -> AudioMixerSnapshot {
        do {
            let mixer = try AudioMixer(audioFormat: .intercomPacketAudio)
            let transmitBus = try mixer.createBus("tx-bus")
            transmitBus.volume = isMuted ? 0 : 1
            try transmitBus.addSource(AVAudioPlayerNode(), id: "microphone-input")
            try addEffects(makeTransmitMixerEffects(), to: transmitBus)

            let receiveMasterBus = try mixer.createBus("rx-master")
            receiveMasterBus.volume = isOutputMuted ? 0 : masterOutputVolume
            try addEffects(makeReceiveMasterMixerEffects(), to: receiveMasterBus)

            for peerID in receivePeerIDsForMixerSnapshot() {
                let peerBus = try mixer.createBus("rx-peer-\(peerID)")
                peerBus.volume = remoteOutputVolume(for: peerID)
                try peerBus.addSource(AVAudioPlayerNode(), id: "rtc-audio-\(peerID)")
                try addEffects(makeReceivePeerMixerEffects(peerID: peerID), to: peerBus)
                try mixer.route(peerBus, to: receiveMasterBus)
            }

            try mixer.routeToOutput(receiveMasterBus)
            return mixer.snapshot()
        } catch {
            return Self.emptyAudioMixerSnapshot()
        }
    }

    private func addEffects(_ effects: [AppMixerEffectRuntime], to bus: MixerBus) throws {
        for effect in effects {
            try bus.addEffect(
                AVAudioMixerNode(),
                id: effect.id,
                state: effect.state,
                parameters: effect.parameters
            )
        }
    }

    private func receivePeerIDsForMixerSnapshot() -> [String] {
        var peerIDs = Set(authenticatedPeerIDs)
        peerIDs.formUnion(connectedPeerIDs)
        peerIDs.formUnion(remoteOutputVolumes.keys)
        peerIDs.formUnion(remoteSoundIsolationEnabled.keys)
        if let selectedGroup {
            peerIDs.formUnion(selectedGroup.members.map(\.id))
        }
        peerIDs.remove(localMemberIdentity.memberID)
        return peerIDs.sorted()
    }

    private func makeTransmitMixerEffects() -> [AppMixerEffectRuntime] {
        [
            soundIsolationMixerEffect(enabled: isSoundIsolationEnabled),
            vadGateMixerEffect(),
            dynamicsProcessorMixerEffect(),
            peakLimiterMixerEffect()
        ]
    }

    private func makeReceivePeerMixerEffects(peerID: String) -> [AppMixerEffectRuntime] {
        [
            soundIsolationMixerEffect(enabled: isRemoteSoundIsolationEnabled(peerID: peerID))
        ]
    }

    private func makeReceiveMasterMixerEffects() -> [AppMixerEffectRuntime] {
        [
            soundIsolationMixerEffect(enabled: receiveMasterSoundIsolationEnabled),
            peakLimiterMixerEffect()
        ]
    }

    private func soundIsolationMixerEffect(enabled: Bool) -> AppMixerEffectRuntime {
        let snapshot = makeVoiceIsolationRuntimeSnapshot(enabled: enabled)
        let state = mixerState(
            enabled: enabled,
            isAvailable: snapshot.state == .active
        )
        return AppMixerEffectRuntime(
            id: "sound-isolation",
            state: state,
            parameters: effectParameters(
                package: "SoundIsolation",
                name: "SoundIsolation",
                shortLabel: state == .bypassed ? "SI Off" : "SI",
                detail: soundIsolationDetail(snapshot: snapshot, enabled: enabled, state: state),
                runtimeState: runtimeStateValue(for: state),
                values: [
                    ("soundType", snapshot.configuration.soundType.rawValue, nil),
                    ("mix", percentage(snapshot.configuration.mix), "%"),
                    ("available", String(snapshot.support.isAvailable), nil)
                ]
            )
        )
    }

    private func vadGateMixerEffect() -> AppMixerEffectRuntime {
        let state: MixerEffectState = isAudioReady ? .active : .unknown
        let runtimeState: String
        if !isAudioReady {
            runtimeState = "idle"
        } else if isMuted {
            runtimeState = "muted"
        } else {
            runtimeState = vadGateRuntimeSnapshot.state.rawValue
        }
        return AppMixerEffectRuntime(
            id: "vad-gate",
            state: state,
            parameters: effectParameters(
                package: "VADGate",
                name: "VADGate",
                shortLabel: vadGateShortLabel(runtimeState: runtimeState),
                detail: vadGateRuntimeDetail,
                runtimeState: runtimeState,
                values: [
                    ("preset", vadSensitivity.rawValue, nil),
                    ("noiseFloorDBFS", String(format: "%.1f", vadGateRuntimeSnapshot.noiseFloorDBFS), "dBFS"),
                    ("gain", String(format: "%.2f", vadGateRuntimeSnapshot.gain), nil)
                ]
            )
        )
    }

    private func dynamicsProcessorMixerEffect() -> AppMixerEffectRuntime {
        let snapshot = makeDynamicsProcessorRuntimeSnapshot()
        let state = mixerState(enabled: true, isAvailable: snapshot.state == .active)
        return AppMixerEffectRuntime(
            id: "dynamics-processor",
            state: state,
            parameters: effectParameters(
                package: "DynamicsProcessor",
                name: "Dynamics",
                shortLabel: "Dyn",
                detail: dynamicsProcessorDetail(snapshot: snapshot, state: state),
                runtimeState: runtimeStateValue(for: state),
                values: [
                    ("threshold", String(format: "%.0f", snapshot.configuration.threshold), "dB"),
                    ("headRoom", String(format: "%.0f", snapshot.configuration.headRoom), "dB"),
                    ("releaseTime", milliseconds(snapshot.configuration.releaseTime), "ms")
                ]
            )
        )
    }

    private func peakLimiterMixerEffect() -> AppMixerEffectRuntime {
        let snapshot = makePeakLimiterRuntimeSnapshot()
        let state = mixerState(enabled: true, isAvailable: snapshot.state == .active)
        return AppMixerEffectRuntime(
            id: "peak-limiter",
            state: state,
            parameters: effectParameters(
                package: "PeakLimiter",
                name: "Peak Limit",
                shortLabel: "Limit",
                detail: peakLimiterDetail(snapshot: snapshot, state: state),
                runtimeState: runtimeStateValue(for: state),
                values: [
                    ("attackTime", milliseconds(snapshot.configuration.attackTime), "ms"),
                    ("decayTime", milliseconds(snapshot.configuration.decayTime), "ms"),
                    ("preGain", String(format: "%.0f", snapshot.configuration.preGain), "dB")
                ]
            )
        )
    }

    private func makeVoiceIsolationRuntimeSnapshot(enabled: Bool) -> VoiceIsolationRuntimeSnapshot {
        VoiceIsolationRuntimeSnapshot(
            configuration: VoiceIsolationConfiguration(soundType: .voice, mix: enabled ? 1 : 0)
        )
    }

    private func makeDynamicsProcessorRuntimeSnapshot() -> DynamicsProcessorRuntimeSnapshot {
        DynamicsProcessorRuntimeSnapshot(configuration: DynamicsProcessorConfiguration())
    }

    private func makePeakLimiterRuntimeSnapshot() -> PeakLimiterRuntimeSnapshot {
        PeakLimiterRuntimeSnapshot(configuration: PeakLimiterConfiguration())
    }

    private func mixerState(enabled: Bool, isAvailable: Bool) -> MixerEffectState {
        if !isAudioReady {
            return .unknown
        }
        if !enabled {
            return .bypassed
        }
        return isAvailable ? .active : .unavailable
    }

    private func effectParameters(
        package: String,
        name: String,
        shortLabel: String,
        detail: String,
        runtimeState: String,
        values: [(id: String, value: String, unit: String?)]
    ) -> [MixerEffectParameterSnapshot] {
        [
            MixerEffectParameterSnapshot(id: "package", value: package),
            MixerEffectParameterSnapshot(id: "name", value: name),
            MixerEffectParameterSnapshot(id: "shortLabel", value: shortLabel),
            MixerEffectParameterSnapshot(id: "detail", value: detail),
            MixerEffectParameterSnapshot(id: "runtimeState", value: runtimeState)
        ] + values.map {
            MixerEffectParameterSnapshot(id: $0.id, value: $0.value, unit: $0.unit)
        }
    }

    private func soundIsolationDetail(
        snapshot: VoiceIsolationRuntimeSnapshot,
        enabled: Bool,
        state: MixerEffectState
    ) -> String {
        switch state {
        case .unknown:
            return "Idle"
        case .bypassed:
            return "Bypassed / mix \(percentage(snapshot.configuration.mix))%"
        case .unavailable:
            return "Unavailable"
        case .active:
            return "\(snapshot.configuration.soundType.rawValue) / mix \(percentage(snapshot.configuration.mix))%"
        }
    }

    private var vadGateRuntimeDetail: String {
        if !isAudioReady {
            return "Idle"
        }
        if isMuted {
            return "Input muted"
        }
        guard let analysis = vadGateRuntimeSnapshot.lastAnalysis else {
            return "Analysis waiting"
        }
        return String(
            format: "%@ / NF %.1f dBFS / TH %.1f dBFS / G %.2f",
            analysis.state == .speech ? "Speech" : "Silence",
            analysis.noiseFloorDBFS,
            analysis.speechThresholdDBFS,
            analysis.gain
        )
    }

    private func vadGateShortLabel(runtimeState: String) -> String {
        switch runtimeState {
        case "speech":
            return "VAD Speech"
        case "muted":
            return "VAD Muted"
        case "silence":
            return "VAD Silent"
        default:
            return "VAD"
        }
    }

    private func dynamicsProcessorDetail(
        snapshot: DynamicsProcessorRuntimeSnapshot,
        state: MixerEffectState
    ) -> String {
        switch state {
        case .unknown:
            return "Idle"
        case .unavailable:
            return "Unavailable"
        case .active:
            return "threshold \(String(format: "%.0f", snapshot.configuration.threshold)) dB"
        case .bypassed:
            return "Bypassed"
        }
    }

    private func peakLimiterDetail(
        snapshot: PeakLimiterRuntimeSnapshot,
        state: MixerEffectState
    ) -> String {
        switch state {
        case .unknown:
            return "Idle"
        case .unavailable:
            return "Unavailable"
        case .active:
            return "attack \(milliseconds(snapshot.configuration.attackTime)) ms"
        case .bypassed:
            return "Bypassed"
        }
    }

    private func runtimeStateValue(for state: MixerEffectState) -> String {
        switch state {
        case .active:
            return "active"
        case .bypassed:
            return "bypassed"
        case .unavailable:
            return "unavailable"
        case .unknown:
            return "idle"
        }
    }

    private func percentage(_ value: Float) -> String {
        String(format: "%.0f", value * 100)
    }

    private func milliseconds(_ value: Float) -> String {
        String(format: "%.0f", value * 1_000)
    }
}

private struct AppMixerEffectRuntime {
    let id: String
    let state: MixerEffectState
    let parameters: [MixerEffectParameterSnapshot]
}
