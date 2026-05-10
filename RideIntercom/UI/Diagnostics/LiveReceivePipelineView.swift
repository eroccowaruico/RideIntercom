import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

struct LiveReceivePipelineView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            CompactPipelineHeader(
                title: "Live RX Pipeline",
                systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
                detail: "RTC -> Decode -> peer buses -> mix -> RX master -> limiter -> output"
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ReceiveRTCPeersGroup(step: rtcReceiveStep, peers: receivePeerBuses)
                ReceiveDecodePeersGroup(
                    step: codecDecodeStep,
                    peers: receivePeerBuses,
                    droppedFrameCount: viewModel.droppedAudioPacketCount
                )
                ReceivePeerBusesGroup(
                    step: peerBusStep,
                    peerBuses: receivePeerBuses,
                    master: receiveMasterMix
                )
                CompactPipelineStepRow(step: receiveMixStep)
                ReceiveMasterMixGroup(
                    step: masterBusStep,
                    effectStep: masterEffectChainStep,
                    effectStages: masterEffectStages,
                    master: receiveMasterMix
                )
                CompactPipelineStepRow(step: outputStep)
            }
        }
        .appDiagnosticsCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveReceivePipelineView")
    }

    private var rtcReceiveStep: PipelineStep {
        guard viewModel.isAudioReady else {
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
        guard viewModel.selectedGroupConnectionState == .localConnected || viewModel.selectedGroupConnectionState == .internetConnected else {
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
        if viewModel.receivedVoicePacketCount > 0 {
            return PipelineStep(
                id: "rtc-receive",
                package: "RTC",
                title: "RTC RX",
                detail: "\(viewModel.routeLabel) / C \(viewModel.connectedPeerCount) / A \(viewModel.authenticatedPeerCount) / RX \(viewModel.receivedVoicePacketCount)",
                icon: "dot.radiowaves.left.and.right",
                state: .passing,
                accessibilityIdentifier: "receive-pipeline-rtc-step"
            )
        }
        return PipelineStep(
            id: "rtc-receive",
            package: "RTC",
            title: "RTC RX",
            detail: "\(viewModel.routeLabel) / C \(viewModel.connectedPeerCount) / A \(viewModel.authenticatedPeerCount)",
            icon: "dot.radiowaves.left.and.right",
            state: .waiting,
            accessibilityIdentifier: "receive-pipeline-rtc-step"
        )
    }

    private var codecDecodeStep: PipelineStep {
        guard viewModel.isAudioReady else {
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
        if viewModel.droppedAudioPacketCount > 0 {
            return PipelineStep(
                id: "codec-decode",
                package: "Codec",
                title: "Decode",
                detail: "Peer decode / DROP \(viewModel.droppedAudioPacketCount)",
                icon: "cpu",
                state: .waiting,
                accessibilityIdentifier: "receive-pipeline-codec-step"
            )
        }
        return PipelineStep(
            id: "codec-decode",
            package: "Codec",
            title: "Decode",
            detail: viewModel.receivedVoicePacketCount > 0 ? "Peer decode / RX \(viewModel.receivedVoicePacketCount)" : "Peer decode Ready",
            icon: viewModel.receivedVoicePacketCount > 0 ? "cpu.fill" : "cpu",
            state: viewModel.receivedVoicePacketCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-codec-step"
        )
    }

    private var peerBusStep: PipelineStep {
        guard viewModel.isAudioReady else {
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
            detail: "\(receivePeerBusCount) peers / RX \(viewModel.receivedVoicePacketCount)",
            icon: "person.2.wave.2",
            state: viewModel.receivedVoicePacketCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-peer-bus-step"
        )
    }

    private var receiveMixStep: PipelineStep {
        guard viewModel.isAudioReady else {
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
            detail: "\(sourceCount) routes -> \(viewModel.audioMixerSnapshot.outputBusID ?? "rx-master")",
            icon: "arrow.triangle.merge",
            state: viewModel.receivedVoicePacketCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-mix-step"
        )
    }

    private var masterBusStep: PipelineStep {
        guard viewModel.isAudioReady else {
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
        let bus = viewModel.mixerBusSnapshot(id: "rx-master")
        return PipelineStep(
            id: "master-bus",
            package: "AudioMixer",
            title: "RX Master",
            detail: bus.map { "\($0.sourceCount) in / \($0.effectCount) FX / OUT \(Int($0.volume * 100))%" }
                ?? "\(receivePeerBusCount) in / OUT \(Int(viewModel.masterOutputVolume * 100))%",
            icon: "waveform.path.ecg",
            state: viewModel.playedAudioFrameCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-master-bus-step"
        )
    }

    private var masterEffectChainStep: PipelineStep {
        guard viewModel.isAudioReady else {
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
            detail: viewModel.receiveMasterEffectChainSnapshot.summary,
            icon: "wand.and.sparkles",
            state: aggregateState(masterEffectStages.map(\.state)),
            accessibilityIdentifier: "receive-pipeline-master-effects-step"
        )
    }

    private var outputStep: PipelineStep {
        if viewModel.isOutputMuted || viewModel.masterOutputVolume == 0 {
            return PipelineStep(
                id: "output",
                package: "SessionManager",
                title: "Output",
                detail: viewModel.isOutputMuted ? "Muted" : "Volume 0%",
                icon: "speaker.slash.fill",
                state: .waiting,
                accessibilityIdentifier: "receive-pipeline-output-step"
            )
        }
        guard viewModel.isAudioReady else {
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
        let snapshot = viewModel.lastOutputStreamOperationReport?.snapshot
        let detail = outputStreamDetail(snapshot: snapshot)
        return PipelineStep(
            id: "output",
            package: "SessionManager",
            title: "Output",
            detail: detail,
            icon: "speaker.wave.2.fill",
            state: viewModel.playedAudioFrameCount > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-output-step"
        )
    }

    private var masterEffectStages: [EffectChainStage] {
        viewModel.receiveMasterEffectChainSnapshot.stages.map(EffectChainStage.init(snapshot:))
    }

    private var receivePeerBuses: [ReceivePeerBusSnapshot] {
        var snapshots: [ReceivePeerBusSnapshot] = []
        if let selectedGroup = viewModel.selectedGroup {
            snapshots = selectedGroup.members.dropFirst().compactMap { member in
                let shouldShowBus = viewModel.authenticatedPeerIDs.contains(member.id)
                    || member.connectionState != .offline
                    || member.receivedAudioPacketCount > 0
                    || member.playedAudioFrameCount > 0
                guard shouldShowBus else { return nil }
                let effectChain = viewModel.receivePeerEffectChainSnapshot(peerID: member.id)
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
                    outputVolume: viewModel.remoteOutputVolume(for: member.id),
                    effectSummary: effectChain.compactSummary,
                    effectStages: effectChain.stages.map(EffectChainStage.init(snapshot:)),
                    isMuted: member.isMuted,
                    state: state(for: member.audioPipelineState)
                )
            }
        }

        let existingPeerIDs = Set(snapshots.map(\.id))
        for peerID in viewModel.authenticatedPeerIDs where !existingPeerIDs.contains(peerID) {
            let effectChain = viewModel.receivePeerEffectChainSnapshot(peerID: peerID)
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
                    outputVolume: viewModel.remoteOutputVolume(for: peerID),
                    effectSummary: effectChain.compactSummary,
                    effectStages: effectChain.stages.map(EffectChainStage.init(snapshot:)),
                    isMuted: false,
                    state: viewModel.receivedVoicePacketCount > 0 ? .passing : .waiting
                )
            )
        }
        return snapshots
    }

    private var receivePeerBusCount: Int {
        max(receivePeerBuses.count, receiveMixerRouteCount, viewModel.authenticatedPeerCount)
    }

    private var receiveMixerRouteCount: Int {
        viewModel.audioMixerSnapshot.routes.filter { $0.destinationBusID == "rx-master" }.count
    }

    private var receiveMasterMix: ReceiveMasterMixSnapshot {
        ReceiveMasterMixSnapshot(
            sourceBusCount: receivePeerBusCount,
            receivedFrameCount: viewModel.receivedVoicePacketCount,
            playedFrameCount: viewModel.playedAudioFrameCount,
            outputLevel: viewModel.diagnosticsOutputLevel,
            outputPeakLevel: viewModel.diagnosticsOutputPeakLevel,
            masterVolume: viewModel.masterOutputVolume,
            effectSummary: viewModel.receiveMasterEffectChainSnapshot.compactSummary,
            isMuted: viewModel.isOutputMuted,
            state: viewModel.playedAudioFrameCount > 0 ? .passing : (viewModel.isAudioReady ? .waiting : .idle)
        )
    }

    private func outputStreamDetail(snapshot: SessionManager.AudioStreamSnapshot?) -> String {
        guard let snapshot else {
            return viewModel.playedAudioFrameCount > 0 ? "Scheduled" : "Ready"
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

private struct ReceivePeerBusSnapshot: Identifiable, Equatable {
    let id: String
    let displayName: String
    let receivedFrameCount: Int
    let queuedFrameCount: Int
    let playedFrameCount: Int
    let level: Float
    let peakLevel: Float
    let connectionLabel: String
    let authenticationLabel: String
    let activeCodec: AudioCodecIdentifier?
    let outputVolume: Float
    let effectSummary: String
    let effectStages: [EffectChainStage]
    let isMuted: Bool
    let state: PipelineStepState
}

private struct ReceiveRTCPeersGroup: View {
    let step: PipelineStep
    let peers: [ReceivePeerBusSnapshot]

    private let columns = [
        GridItem(.adaptive(minimum: 148), spacing: AppSpacing.xs, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            CompactPipelineStepRow(step: step, accessibilityIdentifier: "\(step.accessibilityIdentifier)-summary")

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ReceiveInlineGroupHeader(title: "RTC Peers", detail: "\(peers.count) peers")

                if peers.isEmpty {
                    ReceiveInlineEmptyRow(text: "No connected peer")
                        .accessibilityIdentifier("receive-rtc-peers-empty")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.xs) {
                        ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                            ReceivePeerRTCChip(peer: peer)
                                .accessibilityIdentifier("receive-peer-rtc-\(index)")
                        }
                    }
                }
            }
            .padding(.leading, CompactPipelineLayout.childIndent)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("receive-rtc-peers")
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(step.accessibilityIdentifier)
    }
}

private struct ReceiveDecodePeersGroup: View {
    let step: PipelineStep
    let peers: [ReceivePeerBusSnapshot]
    let droppedFrameCount: Int

    private let columns = [
        GridItem(.adaptive(minimum: 148), spacing: AppSpacing.xs, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            CompactPipelineStepRow(step: step, accessibilityIdentifier: "\(step.accessibilityIdentifier)-summary")

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ReceiveInlineGroupHeader(title: "Peer Decode", detail: dropDetail)

                if peers.isEmpty {
                    ReceiveInlineEmptyRow(text: "No peer codec metadata")
                        .accessibilityIdentifier("receive-codec-peers-empty")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.xs) {
                        ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                            ReceivePeerCodecChip(peer: peer)
                                .accessibilityIdentifier("receive-peer-codec-\(index)")
                        }
                    }
                }
            }
            .padding(.leading, CompactPipelineLayout.childIndent)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("receive-codec-peers")
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(step.accessibilityIdentifier)
    }

    private var dropDetail: String {
        droppedFrameCount > 0 ? "DROP \(droppedFrameCount)" : "\(peers.count) decoders"
    }
}

private struct ReceiveInlineGroupHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Text(title)
                .font(AppTypography.caption2)
                .foregroundStyle(AppColorPalette.textTertiary)

            Text(detail)
                .font(AppTypography.caption2Mono)
                .foregroundStyle(AppColorPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct ReceiveInlineEmptyRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.s) {
            Image(systemName: "minus.circle")
                .foregroundStyle(AppColorPalette.neutral)
                .frame(width: AppSize.iconS)
                .accessibilityHidden(true)

            Text(text)
                .font(AppTypography.caption2Mono)
                .foregroundStyle(AppColorPalette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

private struct ReceivePeerRTCChip: View {
    let peer: ReceivePeerBusSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            Circle()
                .fill(peer.state.color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(peer.displayName)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AppColorPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(peer.connectionLabel) / \(peer.authenticationLabel)")
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(peer.state.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColorPalette.panelSurface.opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("RTC peer \(peer.displayName)")
        .accessibilityValue("\(peer.connectionLabel), \(peer.authenticationLabel)")
    }
}

private struct ReceivePeerCodecChip: View {
    let peer: ReceivePeerBusSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            Circle()
                .fill(peer.state.color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(peer.displayName)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AppColorPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("DEC \(codecLabel(peer.activeCodec))")
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(peer.state.color)
                    .lineLimit(1)

                Text("RX \(peer.receivedFrameCount)")
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(AppColorPalette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColorPalette.panelSurface.opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Decode peer \(peer.displayName)")
        .accessibilityValue("\(codecLabel(peer.activeCodec)), received \(peer.receivedFrameCount)")
    }

    private func codecLabel(_ codec: AudioCodecIdentifier?) -> String {
        guard let codec else { return "Unknown" }
        if codec == .pcm16 { return "PCM" }
        if codec == .mpeg4AACELDv2 { return "AAC" }
        if codec == .opus { return "Opus" }
        if codec == .routeManaged { return "Route" }
        return codec.rawValue
    }
}

private struct ReceiveMasterMixSnapshot: Equatable {
    let sourceBusCount: Int
    let receivedFrameCount: Int
    let playedFrameCount: Int
    let outputLevel: Float
    let outputPeakLevel: Float
    let masterVolume: Float
    let effectSummary: String
    let isMuted: Bool
    let state: PipelineStepState
}

private struct ReceivePeerBusesGroup: View {
    let step: PipelineStep
    let peerBuses: [ReceivePeerBusSnapshot]
    let master: ReceiveMasterMixSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            CompactPipelineStepRow(step: step, accessibilityIdentifier: "\(step.accessibilityIdentifier)-summary")

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ReceiveMixTopologyHeader(master: master)
                if peerBuses.isEmpty {
                    EmptyReceivePeerBusesRow()
                        .accessibilityIdentifier("receive-peer-buses-empty")
                } else {
                    ForEach(Array(peerBuses.enumerated()), id: \.element.id) { index, peerBus in
                        ReceivePeerBusCompactRow(index: index + 1, peerBus: peerBus)
                            .accessibilityIdentifier("receive-peer-bus-\(index)")
                    }
                }
            }
            .padding(.leading, CompactPipelineLayout.childIndent)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("receive-mix-topology")
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(step.accessibilityIdentifier)
    }
}

private struct ReceiveMixTopologyHeader: View {
    let master: ReceiveMasterMixSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Text("Peer Bus List")
                .font(AppTypography.caption2)
                .foregroundStyle(AppColorPalette.textTertiary)

            Text("\(master.sourceBusCount) peer buses -> receive master")
                .font(AppTypography.caption2Mono)
                .foregroundStyle(master.state.color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct EmptyReceivePeerBusesRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.s) {
            Image(systemName: "person.2.slash")
                .foregroundStyle(AppColorPalette.neutral)
                .frame(width: AppSize.iconS)
                .accessibilityHidden(true)

            Text("No authenticated peer bus")
                .font(AppTypography.caption2Mono)
                .foregroundStyle(AppColorPalette.textSecondary)
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No authenticated peer bus")
    }
}

private struct ReceivePeerBusCompactRow: View {
    let index: Int
    let peerBus: ReceivePeerBusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .top, spacing: AppSpacing.s) {
                Circle()
                    .fill(peerBus.state.color)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                        Text("Bus \(index)")
                            .font(AppTypography.caption2Mono)
                            .foregroundStyle(AppColorPalette.textTertiary)
                            .frame(width: 42, alignment: .leading)

                        Text(peerBus.displayName)
                            .font(AppTypography.captionStrong)
                            .foregroundStyle(AppColorPalette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: AppSpacing.s)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.m) {
                            mixerFramesText
                            volumeEffectText
                        }

                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            mixerFramesText
                            volumeEffectText
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VoiceMeterView(
                    level: peerBus.isMuted ? 0 : peerBus.level,
                    peakLevel: peerBus.isMuted ? 0 : peerBus.peakLevel,
                    isMuted: peerBus.isMuted,
                    showsValueText: false
                )
                .frame(width: 72)
            }

            InlineEffectStageChips(
                stageIdentifierPrefix: "receive-peer-\(index)-effect-stage",
                stages: peerBus.effectStages
            )
            .padding(.leading, CompactPipelineLayout.childIndent)
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColorPalette.panelSurface.opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Receive peer bus \(index) \(peerBus.displayName)")
        .accessibilityValue("Mixer received \(peerBus.receivedFrameCount), queued \(peerBus.queuedFrameCount), played \(peerBus.playedFrameCount), volume \(Int(peerBus.outputVolume * 100)) percent, effects \(peerBus.effectSummary)")
    }

    private var mixerFramesText: some View {
        Text("MIX RX \(peerBus.receivedFrameCount) / JIT \(peerBus.queuedFrameCount) / PLAY \(peerBus.playedFrameCount)")
            .font(AppTypography.caption2Mono)
            .foregroundStyle(peerBus.isMuted ? AppColorPalette.warning : peerBus.state.color)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
    }

    private var volumeEffectText: some View {
        Text("VOL \(Int(peerBus.outputVolume * 100))% / FX \(peerBus.effectSummary)")
            .font(AppTypography.caption2Mono)
            .foregroundStyle(AppColorPalette.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InlineEffectStageChips: View {
    let stageIdentifierPrefix: String
    let stages: [EffectChainStage]

    private let columns = [
        GridItem(.adaptive(minimum: 112), spacing: AppSpacing.xs, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.xs) {
            ForEach(stages) { stage in
                EffectChainStageChip(stage: stage)
                    .accessibilityIdentifier("\(stageIdentifierPrefix)-\(stage.id)")
            }
        }
    }
}

private struct ReceiveMasterMixGroup: View {
    let step: PipelineStep
    let effectStep: PipelineStep
    let effectStages: [EffectChainStage]
    let master: ReceiveMasterMixSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            CompactPipelineStepRow(step: step, accessibilityIdentifier: "\(step.accessibilityIdentifier)-summary")

            HStack(alignment: .top, spacing: AppSpacing.s) {
                Circle()
                    .fill(master.state.color)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("\(master.sourceBusCount) buses / RX \(master.receivedFrameCount) / PLAY \(master.playedFrameCount)")
                        .font(AppTypography.caption2Mono)
                        .foregroundStyle(AppColorPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(master.isMuted ? "OUT muted" : "VOL \(Int(master.masterVolume * 100))% / FX \(master.effectSummary)")
                        .font(AppTypography.caption2Mono)
                        .foregroundStyle(master.isMuted ? AppColorPalette.warning : master.state.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VoiceMeterView(
                    level: master.isMuted ? 0 : master.outputLevel,
                    peakLevel: master.isMuted ? 0 : master.outputPeakLevel,
                    isMuted: master.isMuted,
                    showsValueText: false
                )
                .frame(width: 72)
            }
            .padding(.horizontal, AppSpacing.s)
            .padding(.vertical, AppSpacing.xs)
            .background(AppColorPalette.panelSurface.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
            .padding(.leading, CompactPipelineLayout.childIndent)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Receive mix down to master")
            .accessibilityValue("\(master.sourceBusCount) peer buses, played \(master.playedFrameCount)")
            .accessibilityIdentifier("receive-master-mix-card")

            CompactEffectChainGroup(
                step: effectStep,
                title: "RX Master Effects",
                accessibilityIdentifier: "receive-pipeline-master-effects-step",
                stageIdentifierPrefix: "receive-master-effect-stage",
                stages: effectStages
            )
            .padding(.leading, CompactPipelineLayout.childIndent)
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(step.accessibilityIdentifier)
    }
}
