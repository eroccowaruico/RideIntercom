import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

struct ReceivePeerBusesGroup: View {
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

struct ReceiveMixTopologyHeader: View {
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

struct EmptyReceivePeerBusesRow: View {
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

struct ReceivePeerBusCompactRow: View {
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

struct InlineEffectStageChips: View {
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

struct ReceiveMasterMixGroup: View {
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
