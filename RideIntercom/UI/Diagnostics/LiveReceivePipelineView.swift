import SwiftUI
import SessionManager

struct LiveReceivePipelineView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var expandedStage: String?

    var body: some View {
        let presentation = ReceivePipelinePresentation(input: DiagnosticsInput(viewModel))
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            CompactPipelineHeader(title: "Live RX Pipeline", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath", detail: "Peers -> mix -> RX master -> output")
            CompactPipelineStepRow(step: presentation.rtcReceiveStep)
            CompactPipelineStepRow(step: presentation.codecDecodeStep)
            CompactPipelineStepRow(step: presentation.peerBusStep)
            DiagnosticsReceiveDetails(viewModel: viewModel, expandedStage: $expandedStage)
                .id("receive-peers")
            CompactPipelineStepRow(step: presentation.receiveMixStep)
            ReceiveMasterMixGroup(step: presentation.masterBusStep, effectStep: presentation.masterEffectChainStep, effectStages: presentation.masterEffectStages, master: presentation.receiveMasterMix)
            DisclosureGroup(isExpanded: Binding(get: { expandedStage == "receive-output" }, set: { expandedStage = $0 ? "receive-output" : nil })) {
                let stream = viewModel.lastOutputStreamOperationReport?.snapshot
                Text("Device: \(viewModel.audioSessionSnapshot.currentOutput.name)")
                Text("Buffered: \(stream?.bufferedOutputDuration.map { String(format: "%.0f ms", $0 * 1000) } ?? "Not measured") / Resets: \(stream?.playbackResetCount.map(String.init) ?? "Not measured") / frames/s: Not measured")
            } label: { CompactPipelineStepRow(step: presentation.outputStep) }
                .id("receive-output")
        }
        .appDiagnosticsCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveReceivePipelineView")
    }
}
