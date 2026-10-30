import SwiftUI

struct SignedInContentView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Call", systemImage: "waveform.circle.fill", value: .call) {
                NavigationStack {
                    CallEntryView(viewModel: viewModel)
                }
            }
            .accessibilityIdentifier("callTab")

            Tab("Diagnostics", systemImage: "gauge", value: .diagnostics) {
                NavigationStack {
                    DiagnosticsView(viewModel: viewModel)
                        .navigationTitle("Diagnostics")
                }
            }
            .accessibilityIdentifier("diagnosticsTab")

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                NavigationStack {
                    SettingsView(viewModel: viewModel)
                        .navigationTitle("Settings")
                }
            }
            .accessibilityIdentifier("settingsTab")
        }
    }
}
