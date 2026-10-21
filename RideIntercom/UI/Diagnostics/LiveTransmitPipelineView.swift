import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

struct LiveTransmitPipelineView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        let presentation = TransmitPipelinePresentation(input: DiagnosticsInput(viewModel))
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            CompactPipelineHeader(
                title: "Live TX Pipeline",
                systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                detail: "Session -> Input -> VAD -> TX bus -> Codec -> RTC"
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                CompactPipelineStepRow(step: presentation.sessionStep)
                CompactPipelineStepRow(step: presentation.inputStreamStep)
                CompactPipelineStepRow(step: presentation.mixerBusStep)
                CompactEffectChainGroup(
                    step: presentation.mixerEffectChainStep,
                    title: "TX Bus Effects",
                    accessibilityIdentifier: "pipeline-effects-step",
                    stageIdentifierPrefix: "pipeline-effect-stage",
                    stages: presentation.transmitEffectStages
                )
                .padding(.leading, CompactPipelineLayout.childIndent)
                CompactPipelineStepRow(step: presentation.codecStep)
                CompactPipelineStepRow(step: presentation.rtcStep)
            }
        }
        .appDiagnosticsCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveTransmitPipelineView")
    }
}
