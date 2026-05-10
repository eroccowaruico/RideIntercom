import AVFoundation
import AudioCore
import Codec
import CryptoKit
import Foundation
import Logging
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    var audioSessionModeProfile: AudioSessionProfile {
        audioSessionProfile.settingsModeProfile
    }

    var isSpeakerOutputEnabled: Bool {
        audioSessionProfile.defaultToSpeaker || selectedOutputPort == .speaker
    }

    var isSessionEchoCancellationEnabled: Bool {
        if let resolvedValue = lastAudioSessionConfigurationReport?.resolvedConfiguration.prefersEchoCancelledInput {
            return resolvedValue
        }
        guard audioSessionModeProfile == .standard else { return false }
        return audioSessionProfile.prefersEchoCancelledInput
    }

    var canToggleSessionEchoCancellation: Bool {
        audioSessionModeProfile == .standard && !isSpeakerOutputEnabled
    }

    func setAudioSessionProfile(_ profile: AudioSessionProfile) {
        audioSessionProfile = profile
        saveAppSettings()
        guard configureAudioSession(active: isAudioReady) else { return }
        audioErrorMessage = nil
        AppLoggers.settings.info(
            "settings.audio_session.changed",
            metadata: .event("settings.audio_session.changed", [
                "profile": "\(profile.rawValue)"
            ])
        )
    }

    func setAudioSessionModeProfile(_ profile: AudioSessionProfile) {
        let previousOutputPort = selectedOutputPort
        let keepsEchoCancellation = audioSessionProfile.prefersEchoCancelledInput
        let keepsSpeakerOutput = isSpeakerOutputEnabled
        switch profile.settingsModeProfile {
        case .standard:
            audioSessionProfile = keepsEchoCancellation ? .echoCancelledInput : .standard
        case .voiceChat:
            audioSessionProfile = .voiceChat
        case .speakerDefault, .echoCancelledInput:
            audioSessionProfile = .standard
        }
        if keepsSpeakerOutput {
            selectedOutputPort = .speaker
        }
        saveAppSettings()
        guard configureAudioSession(active: isAudioReady) else { return }
        if selectedOutputPort != previousOutputPort {
            refreshOutputRendererIfNeeded()
        }
        audioErrorMessage = nil
        AppLoggers.settings.info(
            "settings.audio_session.changed",
            metadata: .event("settings.audio_session.changed", [
                "profile": "\(audioSessionProfile.rawValue)",
                "speaker": "\(isSpeakerOutputEnabled)"
            ])
        )
    }

    func setSpeakerOutputEnabled(_ enabled: Bool) {
        let previousOutputPort = selectedOutputPort
        if audioSessionProfile == .speakerDefault {
            audioSessionProfile = .standard
        }
        selectedOutputPort = enabled ? .speaker : .systemDefault
        saveAppSettings()
        guard configureAudioSession(active: isAudioReady) else { return }
        if selectedOutputPort != previousOutputPort {
            refreshOutputRendererIfNeeded()
        }
        audioErrorMessage = nil
        AppLoggers.settings.info(
            "settings.audio_speaker.changed",
            metadata: .event("settings.audio_speaker.changed", [
                "enabled": "\(enabled)",
                "profile": "\(audioSessionProfile.rawValue)"
            ])
        )
    }

    func setSessionEchoCancellationEnabled(_ enabled: Bool) {
        guard canToggleSessionEchoCancellation else { return }
        audioSessionProfile = enabled ? .echoCancelledInput : .standard
        saveAppSettings()
        guard configureAudioSession(active: isAudioReady) else { return }
        audioErrorMessage = nil
        AppLoggers.settings.info(
            "settings.echo_cancellation.changed",
            metadata: .event("settings.echo_cancellation.changed", [
                "enabled": "\(isSessionEchoCancellationEnabled)",
                "speaker": "\(isSpeakerOutputEnabled)"
            ])
        )
    }

    func toggleMute() {
        isMuted.toggle()
        applyCurrentVoiceProcessingConfiguration()
        callSession.setLocalMute(isMuted)

        withActiveGroup { group in
            guard !group.members.isEmpty else { return }
            group.members[0].isMuted = isMuted
            if isMuted {
                group.members[0].isTalking = false
                group.members[0].voiceLevel = 0
                group.members[0].voicePeakLevel = 0
            }
        }
        if isMuted {
            localVoicePeakWindow = VoicePeakWindow()
        }
        broadcastControl(.peerMuteState(isMuted: isMuted))
        broadcastMetadataKeepalive()
        publishRuntimePackageReports(force: true)
    }

    func setPreferredTransmitCodec(_ codec: AudioCodecIdentifier) {
        preferredTransmitCodec = codec
        refreshPackageRuntimeSnapshots()
        rebuildAudioPipelineIfRunning()
        setLocalActiveCodec(selectedTransmitCodec)
        saveAppSettings()
        AppLoggers.settings.info(
            "settings.codec.changed",
            metadata: .event("settings.codec.changed", [
                "codec": "\(codec.rawValue)",
                "selectedCodec": "\(selectedTransmitCodec.rawValue)"
            ])
        )
        logCodecFallbackIfNeeded()
        broadcastMetadataKeepalive()
        publishRuntimePackageReports(force: true)
    }

    func setAACELDv2BitRate(_ bitRate: Int) {
        aacELDv2BitRate = Codec.AACELDv2Options(bitRate: bitRate).bitRate
        refreshPackageRuntimeSnapshots()
        setLocalActiveCodec(selectedTransmitCodec)
        rebuildAudioPipelineIfRunning()
        saveAppSettings()
        AppLoggers.settings.info(
            "settings.codec.bitrate_changed",
            metadata: .event("settings.codec.bitrate_changed", [
                "codec": "\(AudioCodecIdentifier.mpeg4AACELDv2.rawValue)",
                "bitRate": "\(aacELDv2BitRate)"
            ])
        )
        publishRuntimePackageReports(force: true)
    }

    func setOpusBitRate(_ bitRate: Int) {
        opusBitRate = Codec.OpusOptions(bitRate: bitRate).bitRate
        refreshPackageRuntimeSnapshots()
        setLocalActiveCodec(selectedTransmitCodec)
        rebuildAudioPipelineIfRunning()
        saveAppSettings()
        AppLoggers.settings.info(
            "settings.codec.bitrate_changed",
            metadata: .event("settings.codec.bitrate_changed", [
                "codec": "\(AudioCodecIdentifier.opus.rawValue)",
                "bitRate": "\(opusBitRate)"
            ])
        )
        publishRuntimePackageReports(force: true)
    }

    func setRTCAudioFormatPreset(_ preset: RTCAudioFormatPreset) {
        guard rtcAudioFormatPreset != preset else { return }
        rtcAudioFormatPreset = preset
        refreshPackageRuntimeSnapshots()
        rebuildAudioPipelineIfRunning()
        saveAppSettings()
        AppLoggers.settings.info(
            "settings.rtc_audio_format.changed",
            metadata: .event("settings.rtc_audio_format.changed", [
                "preset": "\(preset.rawValue)",
                "sampleRate": "\(Int(preset.audioFormat.sampleRate))"
            ])
        )
        publishRuntimePackageReports(force: true)
    }

    nonisolated static func normalizedRTCTransportRoutes(_ routes: Set<RTC.RouteKind>) -> Set<RTC.RouteKind> {
        let normalizedRoutes = routes.intersection(supportedRTCTransportRoutes)
        return normalizedRoutes.isEmpty ? defaultEnabledRTCTransportRoutes : normalizedRoutes
    }

    func isRTCTransportRouteEnabled(_ route: RTC.RouteKind) -> Bool {
        enabledRTCTransportRoutes.contains(route)
    }

    func canToggleRTCTransportRoute(_ route: RTC.RouteKind) -> Bool {
        guard Self.supportedRTCTransportRoutes.contains(route) else { return false }
        return enabledRTCTransportRoutes.count > 1 || !enabledRTCTransportRoutes.contains(route)
    }

    func setRTCTransportRoute(_ route: RTC.RouteKind, enabled: Bool) {
        guard canToggleRTCTransportRoute(route) else { return }

        var routes = enabledRTCTransportRoutes
        if enabled {
            routes.insert(route)
        } else {
            routes.remove(route)
        }
        setRTCTransportRoutes(routes)
    }

    func setRTCTransportRoutes(_ routes: Set<RTC.RouteKind>) {
        let normalizedRoutes = Self.normalizedRTCTransportRoutes(routes)
        guard normalizedRoutes != enabledRTCTransportRoutes else { return }

        if hasAnyActiveGroupConnection {
            disconnect()
        }

        enabledRTCTransportRoutes = normalizedRoutes
        callSession.setEnabledRoutes(normalizedRoutes)
        saveAppSettings()
        AppLoggers.settings.info(
            "settings.rtc_routes.changed",
            metadata: .event("settings.rtc_routes.changed", [
                "enabledRoutes": "\(normalizedRoutes.map(\.rawValue).sorted().joined(separator: ","))"
            ])
        )
        publishRuntimePackageReports(force: true)
    }

    func setVADSensitivity(_ sensitivity: VoiceActivitySensitivity) {
        vadSensitivity = sensitivity
        audioTransmissionController.applyVADSensitivity(sensitivity)
        latestVADAnalysis = nil
        refreshPackageRuntimeSnapshots()
        saveAppSettings()
        AppLoggers.settings.info(
            "settings.vad.changed",
            metadata: .event("settings.vad.changed", ["preset": "\(sensitivity.rawValue)"])
        )
        publishRuntimePackageReports(force: true)
    }

    func setMasterOutputVolume(_ volume: Float) {
        masterOutputVolume = min(2, max(0, volume))
        updateAudioPipelineOutputSettings()
        publishRuntimePackageReports(force: true)
    }

    func remoteOutputVolume(for peerID: String) -> Float {
        remoteOutputVolumes[peerID] ?? Self.defaultRemoteOutputVolume
    }

    func setRemoteOutputVolume(peerID: String, volume: Float) {
        let normalizedVolume = min(1, max(0, volume))
        if normalizedVolume == Self.defaultRemoteOutputVolume {
            remoteOutputVolumes.removeValue(forKey: peerID)
        } else {
            remoteOutputVolumes[peerID] = normalizedVolume
        }
        updateAudioPipelineOutputSettings()
        AppLoggers.settings.info(
            "settings.remote_output_volume.changed",
            metadata: .event("settings.remote_output_volume.changed", [
                "peerID": "\(peerID)",
                "volume": "\(normalizedVolume)"
            ])
        )
        publishRuntimePackageReports(force: true)
    }

    func setSoundIsolationEnabled(_ enabled: Bool) {
        isSoundIsolationEnabled = enabled
        AppLoggers.settings.info(
            "settings.sound_isolation.changed",
            metadata: .event("settings.sound_isolation.changed", [
                "enabled": "\(enabled)"
            ])
        )
        publishRuntimePackageReports(force: true)
    }

    func isRemoteSoundIsolationEnabled(peerID: String) -> Bool {
        remoteSoundIsolationEnabled[peerID] ?? Self.defaultReceiveSoundIsolationEnabled
    }

    func setRemoteSoundIsolationEnabled(peerID: String, enabled: Bool) {
        if enabled == Self.defaultReceiveSoundIsolationEnabled {
            remoteSoundIsolationEnabled.removeValue(forKey: peerID)
        } else {
            remoteSoundIsolationEnabled[peerID] = enabled
        }
        AppLoggers.settings.info(
            "settings.remote_sound_isolation.changed",
            metadata: .event("settings.remote_sound_isolation.changed", [
                "peerID": "\(peerID)",
                "enabled": "\(enabled)"
            ])
        )
        rebuildAudioPipelineIfRunning()
        publishRuntimePackageReports(force: true)
    }

    func setReceiveMasterSoundIsolationEnabled(_ enabled: Bool) {
        receiveMasterSoundIsolationEnabled = enabled
        AppLoggers.settings.info(
            "settings.receive_master_sound_isolation.changed",
            metadata: .event("settings.receive_master_sound_isolation.changed", [
                "enabled": "\(enabled)"
            ])
        )
        rebuildAudioPipelineIfRunning()
        publishRuntimePackageReports(force: true)
    }

    func setInputPort(_ port: AudioPortInfo) {
        selectedInputPort = port
        guard configureAudioSession(active: isAudioReady) else { return }
        audioErrorMessage = nil
        AppLoggers.settings.info(
            "settings.audio_device.changed",
            metadata: .event("settings.audio_device.changed", [
                "direction": "input",
                "selection": "\(port.id)"
            ])
        )
    }

    func setOutputPort(_ port: AudioPortInfo) {
        let previousOutputPort = selectedOutputPort
        selectedOutputPort = port
        guard configureAudioSession(active: isAudioReady) else { return }
        if selectedOutputPort != previousOutputPort {
            refreshOutputRendererIfNeeded()
        }
        audioErrorMessage = nil
        AppLoggers.settings.info(
            "settings.audio_device.changed",
            metadata: .event("settings.audio_device.changed", [
                "direction": "output",
                "selection": "\(port.id)"
            ])
        )
    }

    func setDuckOthersEnabled(_ enabled: Bool) {
        isDuckOthersEnabled = enabled
        refreshOtherAudioDuckingState()
        publishRuntimePackageReports(force: true)
        audioErrorMessage = nil
        AppLoggers.settings.info(
            "settings.ducking.changed",
            metadata: .event("settings.ducking.changed", [
                "enabled": "\(enabled)"
            ])
        )
    }

    func toggleOutputMute() {
        isOutputMuted.toggle()
        callSession.setOutputMute(isOutputMuted)
        updateAudioPipelineOutputSettings()
        publishRuntimePackageReports(force: true)
    }

    func resetAllSettings() {
        setInputPort(.systemDefault)
        setOutputPort(.systemDefault)
        setAudioSessionProfile(Self.defaultAudioSessionProfile)
        setDuckOthersEnabled(Self.defaultDuckOthersEnabled)
        setVADSensitivity(Self.defaultVADSensitivity)
        setSoundIsolationEnabled(Self.defaultSoundIsolationEnabled)
        setPreferredTransmitCodec(Self.defaultTransmitCodec)
        setRTCAudioFormatPreset(Self.defaultRTCAudioFormatPreset)
        setAACELDv2BitRate(Self.defaultAACELDv2BitRate)
        setOpusBitRate(Self.defaultOpusBitRate)
        setRTCTransportRoutes(Self.defaultEnabledRTCTransportRoutes)
        setMasterOutputVolume(Self.defaultMasterOutputVolume)
        let resetRemoteOutputPeerIDs = Array(remoteOutputVolumes.keys)
        remoteOutputVolumes.removeAll()
        _ = resetRemoteOutputPeerIDs
        updateAudioPipelineOutputSettings()
        receiveMasterSoundIsolationEnabled = Self.defaultReceiveSoundIsolationEnabled
        remoteSoundIsolationEnabled.removeAll()
        isOutputMuted = false
        callSession.setOutputMute(false)
        updateAudioPipelineOutputSettings()
        publishRuntimePackageReports(force: true)
        let operationID = UUID().uuidString
        AppLoggers.settings.notice(
            "settings.reset",
            metadata: .event("settings.reset", [
                "operationID": "\(operationID)"
            ])
        )
    }

    private func saveAppSettings() {
        appSettingsStore.save(AppSettings(
            audioSessionProfile: audioSessionProfile,
            vadSensitivity: vadSensitivity,
            preferredTransmitCodec: preferredTransmitCodec,
            rtcAudioFormatPreset: rtcAudioFormatPreset,
            aacELDv2BitRate: aacELDv2BitRate,
            opusBitRate: opusBitRate,
            enabledRTCTransportRoutes: enabledRTCTransportRoutes
        ))
    }

    private func logCodecFallbackIfNeeded() {
        guard preferredTransmitCodec != selectedTransmitCodec else { return }
        AppLoggers.audio.notice(
            "audio.codec.fallback",
            metadata: .event("audio.codec.fallback", [
                "requestedCodec": "\(preferredTransmitCodec.rawValue)",
                "selectedCodec": "\(selectedTransmitCodec.rawValue)",
                "reason": "unavailable_or_route_unsupported"
            ])
        )
    }
}
