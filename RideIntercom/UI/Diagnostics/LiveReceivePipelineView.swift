import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

struct LiveReceivePipelineView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        let presentation = ReceivePipelinePresentation(input: DiagnosticsInput(viewModel))
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            CompactPipelineHeader(
                title: "Live RX Pipeline",
                systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
                detail: "RTC -> Decode -> peer buses -> mix -> RX master -> output"
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ReceiveRTCPeersGroup(step: presentation.rtcReceiveStep, peers: presentation.receivePeerBuses)
                ReceiveDecodePeersGroup(
                    step: presentation.codecDecodeStep,
                    peers: presentation.receivePeerBuses,
                    droppedFrameCount: presentation.input.droppedAudioPacketCount
                )
                ReceivePeerBusesGroup(
                    step: presentation.peerBusStep,
                    peerBuses: presentation.receivePeerBuses,
                    master: presentation.receiveMasterMix
                )
                CompactPipelineStepRow(step: presentation.receiveMixStep)
                ReceiveMasterMixGroup(
                    step: presentation.masterBusStep,
                    effectStep: presentation.masterEffectChainStep,
                    effectStages: presentation.masterEffectStages,
                    master: presentation.receiveMasterMix
                )
                CompactPipelineStepRow(step: presentation.outputStep)
            }
        }
        .appDiagnosticsCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveReceivePipelineView")
    }
}
