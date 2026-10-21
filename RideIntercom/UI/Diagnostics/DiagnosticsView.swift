import SwiftUI

struct DiagnosticsView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.l) {
                    DiagnosticsOverviewGrid(rows: viewModel.diagnosticsOverviewRows)
                    GroupBox("Internet Service") {
                        VStack(alignment: .leading, spacing: AppSpacing.m) {
                            Text(viewModel.internetCheckMessage)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("internetServiceCheckStatus")
                            Button("Check Internet Service") {
                                Task { await viewModel.checkInternetService() }
                            }
                            .disabled(viewModel.isCheckingInternet || !viewModel.hasInternetCredentials)
                            .accessibilityIdentifier("checkInternetService")
                            Text("Checks configuration and device authorization without starting a call. Audio Check in Settings tests this device's microphone and speaker.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LiveTransmitPipelineView(viewModel: viewModel)
                    LiveReceivePipelineView(viewModel: viewModel)
                }
                .padding(AppSpacing.l)
            }
            .accessibilityIdentifier("diagnosticsScrollView")
        }
    }
}
