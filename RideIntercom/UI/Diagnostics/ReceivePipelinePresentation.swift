import AudioCore
import AudioMixer
import RTC
import SessionManager

/// Pure projection of one captured input; owns no live state.
struct ReceivePipelinePresentation {
    let input: DiagnosticsInput
    var rtcReceiveStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "rtc-receive",
                package: "RTC",
                title: "RTC RX",
                detail: "Media Idle",
                icon: "dot.radiowaves.left.and.right",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-rtc-step"
            )
        }
        guard input.selectedGroupConnectionState == .localConnected || input.selectedGroupConnectionState == .internetConnected else {
            return PipelineStep(
                id: "rtc-receive",
                package: "RTC",
                title: "RTC RX",
                detail: "Control Waiting",
                icon: "dot.radiowaves.left.and.right",
                state: .waiting,
                accessibilityIdentifier: "receive-pipeline-rtc-step"
            )
        }
        if input.receivedVoicePacketCount > 0 {
            return PipelineStep(
                id: "rtc-receive",
                package: "RTC",
                title: "RTC RX",
                detail: "\(input.routeLabel) / C \(input.connectedPeerCount) / A \(input.authenticatedPeerCount) / RX \(input.receivedVoicePacketCount)",
                icon: "dot.radiowaves.left.and.right",
                state: .passing,
                accessibilityIdentifier: "receive-pipeline-rtc-step"
            )
        }
        return PipelineStep(
            id: "rtc-receive",
            package: "RTC",
            title: "RTC RX",
            detail: "\(input.routeLabel) / C \(input.connectedPeerCount) / A \(input.authenticatedPeerCount)",
            icon: "dot.radiowaves.left.and.right",
            state: .waiting,
            accessibilityIdentifier: "receive-pipeline-rtc-step"
        )
    }

    var codecDecodeStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "codec-decode",
                package: "Codec",
                title: "Decode",
                detail: "Idle",
                icon: "cpu",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-codec-step"
            )
        }
        if input.droppedAudioPacketCount > 0 {
            return PipelineStep(
                id: "codec-decode",
                package: "Codec",
                title: "Decode",
                detail: "Peer decode / DROP \(input.droppedAudioPacketCount)",
                icon: "cpu",
                state: .waiting,
                accessibilityIdentifier: "receive-pipeline-codec-step"
            )
        }
        return PipelineStep(
            id: "codec-decode",
            package: "Codec",
            title: "Decode",
            detail: input.receivedVoicePacketCount > 0 ? "Peer decode / RX \(input.receivedVoicePacketCount)" : "Peer decode Ready",
            icon: input.receivedVoicePacketCount > 0 ? "cpu.fill" : "cpu",
            state: input.receivedVoicePacketCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-codec-step"
        )
    }

    var peerBusStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "peer-bus",
                package: "AudioMixer",
                title: "Peer Buses",
                detail: "Idle",
                icon: "person.2.wave.2",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-peer-bus-step"
            )
        }
        return PipelineStep(
            id: "peer-bus",
            package: "AudioMixer",
            title: "Peer Buses",
            detail: "\(receivePeerBusCount) peers / RX \(input.receivedVoicePacketCount)",
            icon: "person.2.wave.2",
            state: input.receivedVoicePacketCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-peer-bus-step"
        )
    }

    var receiveMixStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "receive-mix",
                package: "AudioMixer",
                title: "Mix Down",
                detail: "Idle",
                icon: "arrow.triangle.merge",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-mix-step"
            )
        }
        let sourceCount = receivePeerBusCount
        return PipelineStep(
            id: "receive-mix",
            package: "AudioMixer",
            title: "Mix Down",
            detail: "\(sourceCount) routes -> \(input.audioMixerSnapshot.outputBusID ?? "rx-master")",
            icon: "arrow.triangle.merge",
            state: input.receivedVoicePacketCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-mix-step"
        )
    }

    var masterBusStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "master-bus",
                package: "AudioMixer",
                title: "RX Master",
                detail: "Idle",
                icon: "waveform.path.ecg",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-master-bus-step"
            )
        }
        let bus = input.mixerBusSnapshot(id: "rx-master")
        return PipelineStep(
            id: "master-bus",
            package: "AudioMixer",
            title: "RX Master",
            detail: bus.map { "\($0.sourceCount) in / \($0.effectCount) FX / OUT \(Int($0.volume * 100))%" }
                ?? "\(receivePeerBusCount) in / OUT \(Int(input.masterOutputVolume * 100))%",
            icon: "waveform.path.ecg",
            state: input.playedAudioFrameCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-master-bus-step"
        )
    }

    var masterEffectChainStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "master-effects",
                package: "AudioMixer",
                title: "Master FX",
                detail: "Idle",
                icon: "wand.and.sparkles",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-master-effects-step"
            )
        }
        return PipelineStep(
            id: "master-effects",
            package: "AudioMixer",
            title: "Master FX",
            detail: input.receiveMasterEffectChainSnapshot.summary,
            icon: "wand.and.sparkles",
            state: aggregateState(masterEffectStages.map(\.state)),
            accessibilityIdentifier: "receive-pipeline-master-effects-step"
        )
    }

    var outputStep: PipelineStep {
        if input.isOutputMuted || input.masterOutputVolume == 0 {
            return PipelineStep(
                id: "output",
                package: "SessionManager",
                title: "Output",
                detail: input.isOutputMuted ? "Muted" : "Volume 0%",
                icon: "speaker.slash.fill",
                state: .waiting,
                accessibilityIdentifier: "receive-pipeline-output-step"
            )
        }
        guard input.isAudioReady else {
            return PipelineStep(
                id: "output",
                package: "SessionManager",
                title: "Output",
                detail: "Idle",
                icon: "speaker",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-output-step"
            )
        }
        let snapshot = input.lastOutputStreamOperationReport?.snapshot
        let detail = outputStreamDetail(snapshot: snapshot)
        return PipelineStep(
            id: "output",
            package: "SessionManager",
            title: "Output",
            detail: detail,
            icon: "speaker.wave.2.fill",
            state: input.playedAudioFrameCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-output-step"
        )
    }

    var masterEffectStages: [EffectChainStage] {
        input.receiveMasterEffectChainSnapshot.stages.map(EffectChainStage.init(snapshot:))
    }

    var receivePeerBuses: [ReceivePeerBusSnapshot] {
        var snapshots: [ReceivePeerBusSnapshot] = []
        if let selectedGroup = input.selectedGroup {
            snapshots = selectedGroup.members.dropFirst().compactMap { member in
                let shouldShowBus = input.authenticatedPeerIDs.contains(member.id)
                    || member.connectionState != .offline
                    || member.receivedAudioPacketCount > 0
                    || member.playedAudioFrameCount > 0
                guard shouldShowBus else { return nil }
                let effectChain = input.receivePeerEffectChainSnapshot(peerID: member.id)
                return ReceivePeerBusSnapshot(
                    id: member.id,
                    displayName: member.displayName,
                    receivedFrameCount: member.receivedAudioPacketCount,
                    queuedFrameCount: member.queuedAudioFrameCount,
                    playedFrameCount: member.playedAudioFrameCount,
                    level: member.voiceLevel,
                    peakLevel: member.voicePeakLevel,
                    connectionLabel: connectionLabel(member.connectionState),
                    authenticationLabel: member.authenticationState.rawValue,
                    activeCodec: member.activeCodec,
                    outputVolume: input.remoteOutputVolume(for: member.id),
                    effectSummary: effectChain.compactSummary,
                    effectStages: effectChain.stages.map(EffectChainStage.init(snapshot:)),
                    isMuted: member.isMuted,
                    state: state(for: member.audioPipelineState)
                )
            }
        }

        let existingPeerIDs = Set(snapshots.map(\.id))
        for peerID in input.authenticatedPeerIDs where !existingPeerIDs.contains(peerID) {
            let effectChain = input.receivePeerEffectChainSnapshot(peerID: peerID)
            snapshots.append(
                ReceivePeerBusSnapshot(
                    id: peerID,
                    displayName: peerID,
                    receivedFrameCount: 0,
                    queuedFrameCount: 0,
                    playedFrameCount: 0,
                    level: 0,
                    peakLevel: 0,
                    connectionLabel: "Connected",
                    authenticationLabel: PeerAuthenticationState.authenticated.rawValue,
                    activeCodec: nil,
                    outputVolume: input.remoteOutputVolume(for: peerID),
                    effectSummary: effectChain.compactSummary,
                    effectStages: effectChain.stages.map(EffectChainStage.init(snapshot:)),
                    isMuted: false,
                    state: input.receivedVoicePacketCount > 0 ? .passing : .waiting
                )
            )
        }
        return snapshots
    }

    var receivePeerBusCount: Int {
        max(receivePeerBuses.count, receiveMixerRouteCount, input.authenticatedPeerCount)
    }

    var receiveMixerRouteCount: Int {
        input.audioMixerSnapshot.routes.filter { $0.destinationBusID == "rx-master" }.count
    }

    var receiveMasterMix: ReceiveMasterMixSnapshot {
        ReceiveMasterMixSnapshot(
            sourceBusCount: receivePeerBusCount,
            receivedFrameCount: input.receivedVoicePacketCount,
            playedFrameCount: input.playedAudioFrameCount,
            outputLevel: input.diagnosticsOutputLevel,
            outputPeakLevel: input.diagnosticsOutputPeakLevel,
            masterVolume: input.masterOutputVolume,
            effectSummary: input.receiveMasterEffectChainSnapshot.compactSummary,
            isMuted: input.isOutputMuted,
            state: input.playedAudioFrameCount > 0 ? .passing : (input.isAudioReady ? .waiting : .idle)
        )
    }

    private func outputStreamDetail(snapshot: SessionManager.AudioStreamSnapshot?) -> String {
        guard let snapshot else {
            return input.playedAudioFrameCount > 0 ? "Scheduled" : "Ready"
        }
        return "\(snapshot.isRunning ? "Run" : "Idle") / \(streamFormatSummary(snapshot.actualHardwareFormat)) / F \(snapshot.processedFrameCount)"
    }

    private func streamFormatSummary(_ format: AudioFormat) -> String {
        "\(Int(format.sampleRate / 1_000))k/\(format.channelCount)ch"
    }

    private func connectionLabel(_ state: PeerConnectionState) -> String {
        switch state {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .offline:
            return "Offline"
        }
    }

    private func aggregateState(_ states: [PipelineStepState]) -> PipelineStepState {
        if states.contains(.blocked) { return .blocked }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.passing) { return .passing }
        return .idle
    }

    private func state(for audioPipelineState: AudioPipelineState) -> PipelineStepState {
        switch audioPipelineState {
        case .receiving, .playing:
            return .passing
        case .received:
            return .waiting
        case .idle:
            return .idle
        }
    }
}
