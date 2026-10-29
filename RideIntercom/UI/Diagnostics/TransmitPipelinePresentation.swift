import AudioCore
import AudioMixer
import RTC
import SessionManager

/// Pure projection of one captured input; owns no live state.
struct TransmitPipelinePresentation {
    let input: DiagnosticsInput
    var sessionStep: PipelineStep {
        if input.audioErrorMessage != nil {
            return PipelineStep(
                id: "session",
                package: "SessionManager",
                title: "Session",
                detail: "Error",
                icon: "waveform.badge.exclamationmark",
                state: .blocked,
                accessibilityIdentifier: "pipeline-session-step"
            )
        }
        if input.audioSessionSnapshot.isActive {
            return PipelineStep(
                id: "session",
                package: "SessionManager",
                title: "Session",
                detail: input.audioSessionProfile.label,
                icon: "waveform",
                state: .passing,
                accessibilityIdentifier: "pipeline-session-step"
            )
        }
        if input.lastAudioSessionConfigurationReport != nil {
            return PipelineStep(
                id: "session",
                package: "SessionManager",
                title: "Session",
                detail: "Configured",
                icon: "waveform",
                state: .waiting,
                accessibilityIdentifier: "pipeline-session-step"
            )
        }
        return PipelineStep(
            id: "session",
            package: "SessionManager",
            title: "Session",
            detail: "Idle",
            icon: "waveform",
            state: .idle,
            accessibilityIdentifier: "pipeline-session-step"
        )
    }

    var inputStreamStep: PipelineStep {
        if input.isMuted {
            return PipelineStep(
                id: "input",
                package: "SessionManager",
                title: "Input",
                detail: inputStreamDetail("Muted"),
                icon: "mic.slash.fill",
                state: .waiting,
                accessibilityIdentifier: "pipeline-input-step"
            )
        }
        guard input.isAudioReady else {
            return PipelineStep(
                id: "input",
                package: "SessionManager",
                title: "Input",
                detail: "Idle",
                icon: "mic",
                state: .idle,
                accessibilityIdentifier: "pipeline-input-step"
            )
        }
        let snapshot = input.lastInputStreamOperationReport?.snapshot ?? input.lastVoiceProcessingOperationReport?.snapshot
        let isRunning = snapshot?.isRunning ?? input.isMicrophoneCaptureRunning
        return PipelineStep(
            id: "input",
            package: "SessionManager",
            title: "Input",
            detail: inputStreamDetail(isRunning ? "Run" : "Starting"),
            icon: isRunning ? "mic.fill" : "mic",
            state: isRunning ? .passing : .waiting,
            accessibilityIdentifier: "pipeline-input-step"
        )
    }

    var mixerBusStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "mixer",
                package: "AudioMixer",
                title: "TX Bus",
                detail: "Idle",
                icon: "slider.horizontal.3",
                state: .idle,
                accessibilityIdentifier: "pipeline-mixer-step"
            )
        }
        let bus = input.mixerBusSnapshot(id: "tx-bus")
        return PipelineStep(
            id: "mixer",
            package: "AudioMixer",
            title: "TX Bus",
            detail: bus.map { "\($0.sourceCount) in / \($0.effectCount) FX" } ?? "Snapshot waiting",
            icon: "slider.horizontal.3",
            state: .passing,
            accessibilityIdentifier: "pipeline-mixer-step"
        )
    }

    var mixerEffectChainStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "effect-chain",
                package: "AudioMixer",
                title: "FX Chain",
                detail: "Idle",
                icon: "wand.and.sparkles",
                state: .idle,
                accessibilityIdentifier: "pipeline-effects-step"
            )
        }
        let state = effectChainState
        return PipelineStep(
            id: "effect-chain",
            package: "AudioMixer",
            title: "FX Chain",
            detail: effectChainPipelineDetail,
            icon: "wand.and.sparkles",
            state: state,
            accessibilityIdentifier: "pipeline-effects-step"
        )
    }

    var codecStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "codec",
                package: "Codec",
                title: "Codec",
                detail: "Idle",
                icon: "cpu",
                state: .idle,
                accessibilityIdentifier: "pipeline-codec-step"
            )
        }
        let isFallback = input.preferredTransmitCodec != input.selectedTransmitCodec
        return PipelineStep(
            id: "codec",
            package: "Codec",
            title: "Codec",
            detail: isFallback ? "\(codecPipelineDetail) / Fallback" : codecPipelineDetail,
            icon: isFallback ? "cpu" : "cpu.fill",
            state: isFallback ? .waiting : codecState,
            accessibilityIdentifier: "pipeline-codec-step"
        )
    }

    var rtcStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "rtc",
                package: "RTC",
                title: "RTC",
                detail: "Media Idle",
                icon: "dot.radiowaves.left.and.right",
                state: .idle,
                accessibilityIdentifier: "pipeline-rtc-step"
            )
        }
        guard input.selectedGroupConnectionState == .localConnected || input.selectedGroupConnectionState == .internetConnected else {
            return PipelineStep(
                id: "rtc",
                package: "RTC",
                title: "RTC",
                detail: "Control Waiting",
                icon: "dot.radiowaves.left.and.right",
                state: .waiting,
                accessibilityIdentifier: "pipeline-rtc-step"
            )
        }
        guard input.sentVoicePacketCount > 0 else {
            return PipelineStep(
                id: "rtc",
                package: "RTC",
                title: "RTC",
                detail: "\(input.routeLabel) Ready",
                icon: "dot.radiowaves.left.and.right",
                state: .waiting,
                accessibilityIdentifier: "pipeline-rtc-step"
            )
        }
        return PipelineStep(
            id: "rtc",
            package: "RTC",
            title: "RTC",
            detail: "\(input.routeLabel) TX \(input.sentVoicePacketCount)",
            icon: "dot.radiowaves.left.and.right",
            state: .passing,
            accessibilityIdentifier: "pipeline-rtc-step"
        )
    }

    var effectChainState: PipelineStepState {
        aggregateState(transmitEffectStages.map(\.state))
    }

    var codecState: PipelineStepState {
        input.isVoiceActive ? .passing : .waiting
    }

    var transmitEffectStages: [EffectChainStage] {
        input.transmitEffectChainSnapshot.stages.map(EffectChainStage.init(snapshot:))
    }

    var effectChainPipelineDetail: String {
        input.transmitEffectChainSnapshot.summary
    }

    private func inputStreamDetail(_ prefix: String) -> String {
        let snapshot = input.lastInputStreamOperationReport?.snapshot ?? input.lastVoiceProcessingOperationReport?.snapshot
        guard let snapshot else { return prefix }
        return "\(prefix) / \(streamFormatSummary(snapshot.actualHardwareFormat)) / F \(snapshot.processedFrameCount)"
    }

    private func streamFormatSummary(_ format: AudioFormat) -> String {
        "\(Int(format.sampleRate / 1_000))k/\(format.channelCount)ch"
    }

    var codecPipelineDetail: String {
        let requested = codecShortLabel(input.preferredTransmitCodec)
        let selected = codecShortLabel(input.selectedTransmitCodec)
        if requested == selected { return selected }
        return "\(requested) -> \(selected)"
    }

    private func codecShortLabel(_ codec: AudioCodecIdentifier) -> String {
        if codec == .pcm16 { return "PCM" }
        if codec == .mpeg4AACELD || codec == .mpeg4AACELDv2 { return "AAC" }
        if codec == .opus { return "Opus" }
        return codec.rawValue
    }

    private func aggregateState(_ states: [PipelineStepState]) -> PipelineStepState {
        if states.contains(.blocked) { return .blocked }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.passing) { return .passing }
        return .idle
    }
}
