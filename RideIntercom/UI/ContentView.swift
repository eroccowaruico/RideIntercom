import SwiftUI
import RTC

struct ContentView: View {
    @State private var viewModel = IntercomViewModel.makeForCurrentProcess()
    @State private var selectedTab: AppTab = .call

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
        .onOpenURL { url in
            do {
                try viewModel.acceptInviteURL(url)
            } catch {
                if viewModel.groupErrorMessage == nil {
                    viewModel.groupErrorMessage = "This invitation could not be opened or saved. Ask for a valid invite and try again."
                }
            }
            selectedTab = .call
        }
    }
}

#Preview {
    ContentView()
}
