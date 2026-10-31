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
        audioErrorMessage = nil
        if selectedOutputPort != previousOutputPort {
            refreshAudioDevicesIfNeeded()
        }
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
        audioErrorMessage = nil
        if selectedOutputPort != previousOutputPort {
            refreshAudioDevicesIfNeeded()
        }
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
        setCallMuted(!isMuted, for: currentCallReference)
    }

    func applyLocalMute(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        audioPipeline.setInputMuted(isMuted)
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
        guard preferredTransmitCodec != codec else { return }
        preferredTransmitCodec = codec
        applyEncodingSettings(event: "settings.codec.changed", metadata: ["codec": "\(codec.rawValue)"],
            announcesCodec: true)
    }

    var availableAACBitRates: [Int] {
        AppAudioCodecBridge.availableAACBitRates(format: rtcAudioFormatPreset.audioFormat)
    }

    func setAACELDv2BitRate(_ bitRate: Int) {
        let normalized = AppAudioCodecBridge.normalizedAACBitRate(bitRate, format: rtcAudioFormatPreset.audioFormat)
        guard aacELDv2BitRate != normalized else { return }
        aacELDv2BitRate = normalized
        applyEncodingSettings(event: "settings.codec.bitrate_changed", metadata: [
            "codec": "\(AudioCodecIdentifier.mpeg4AACELD.rawValue)", "bitRate": "\(normalized)"])
    }

    func setOpusBitRate(_ bitRate: Int) {
        let normalized = Codec.OpusOptions(bitRate: bitRate).bitRate
        guard opusBitRate != normalized else { return }
        opusBitRate = normalized
        applyEncodingSettings(event: "settings.codec.bitrate_changed", metadata: [
            "codec": "\(AudioCodecIdentifier.opus.rawValue)", "bitRate": "\(normalized)"])
    }

    func setRTCAudioFormatPreset(_ preset: RTCAudioFormatPreset) {
        guard rtcAudioFormatPreset != preset else { return }
        rtcAudioFormatPreset = preset
        aacELDv2BitRate = AppAudioCodecBridge.normalizedAACBitRate(aacELDv2BitRate, format: preset.audioFormat)
        opusBitRate = Codec.OpusOptions(bitRate: opusBitRate).bitRate
        applyEncodingSettings(event: "settings.rtc_audio_format.changed", metadata: [
            "preset": "\(preset.rawValue)", "sampleRate": "\(Int(preset.audioFormat.sampleRate))"])
    }

    /// UI differences end at normalization. Every encoding setting uses the same
    /// complete snapshot, DSP transition and RTC policy publication, in that order.
    private func applyEncodingSettings(event: String, metadata: Logging.Logger.Metadata, announcesCodec: Bool = false) {
        refreshPackageRuntimeSnapshots()
        updateAudioPipelineCodecSettings()
        setLocalActiveCodec(selectedTransmitCodec)
        saveAppSettings()
        var values = metadata
        if announcesCodec { values["selectedCodec"] = "\(selectedTransmitCodec.rawValue)" }
        AppLoggers.settings.info("\(event)", metadata: .event(event, values))
        if announcesCodec {
            logCodecFallbackIfNeeded()
            broadcastMetadataKeepalive()
        }
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
        audioPipeline.applyVADSensitivity(sensitivity)
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
        updateAudioPipelineEffectSettings()
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
        updateAudioPipelineEffectSettings()
    }

    func setReceiveMasterSoundIsolationEnabled(_ enabled: Bool) {
        receiveMasterSoundIsolationEnabled = enabled
        AppLoggers.settings.info(
            "settings.receive_master_sound_isolation.changed",
            metadata: .event("settings.receive_master_sound_isolation.changed", [
                "enabled": "\(enabled)"
            ])
        )
        updateAudioPipelineEffectSettings()
    }

    func setInputPort(_ port: AudioPortInfo) {
        let previousInputPort = selectedInputPort
        selectedInputPort = port
        guard configureAudioSession(active: isAudioReady) else { return }
        audioErrorMessage = nil
        if selectedInputPort != previousInputPort { refreshAudioDevicesIfNeeded() }
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
        audioErrorMessage = nil
        if selectedOutputPort != previousOutputPort {
            refreshAudioDevicesIfNeeded()
        }
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
        applyCurrentVoiceProcessingConfiguration()
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
        updateAudioPipelineEffectSettings()
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

    func saveAppSettings() {
        guard canStartCalls else { return }
        var settings = AppSettings(
            recentCallDestination: storedRecentCallDestination,
            audioSessionProfile: audioSessionProfile,
            vadSensitivity: vadSensitivity,
            preferredTransmitCodec: preferredTransmitCodec,
            rtcAudioFormatPreset: rtcAudioFormatPreset,
            aacELDv2BitRate: aacELDv2BitRate,
            opusBitRate: opusBitRate,
            enabledRTCTransportRoutes: enabledRTCTransportRoutes
        )
        settings.menuBarEnabled = menuBarEnabled
        settings.liveActivityEnabled = liveActivityEnabled
        settings.interfaceMode = interfaceMode
        appSettingsStore.save(settings)
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
