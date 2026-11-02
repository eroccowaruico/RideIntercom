import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

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
                        .foregroundStyle(AppColorPalette.textPrimary)
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
