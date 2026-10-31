import SwiftUI

struct SignedInContentView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Call", systemImage: "phone", value: .call) {
                NavigationStack {
                    if viewModel.interfaceMode == .standard {
                        StandardCallView(viewModel: viewModel, selectedTab: $selectedTab)
                    } else {
                        CallEntryView(viewModel: viewModel)
                    }
                }
            }.accessibilityIdentifier("callTab")
            if viewModel.interfaceMode == .standard {
                Tab("Users", systemImage: "person.2", value: .users) {
                    NavigationStack { StandardUsersView(viewModel: viewModel, selectedTab: $selectedTab) }
                }.accessibilityIdentifier("usersTab")
                Tab("Groups", systemImage: "person.3", value: .groups) {
                    NavigationStack { StandardGroupsView(viewModel: viewModel, selectedTab: $selectedTab) }
                }.accessibilityIdentifier("groupsTab")
            } else {
                Tab("Diagnostics", systemImage: "gauge", value: .diagnostics) {
                    NavigationStack { DiagnosticsView(viewModel: viewModel).navigationTitle("Diagnostics") }
                }.accessibilityIdentifier("diagnosticsTab")
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack { SettingsView(viewModel: viewModel).navigationTitle("Settings") }
            }.accessibilityIdentifier("settingsTab")
        }
        .task { await viewModel.storeAccess.start() }
        .task { await viewModel.notifications.refresh() }
        .onChange(of: viewModel.interfaceMode) { _, mode in selectedTab = selectedTab.available(in: mode) }
        .onAppear { selectedTab = selectedTab.available(in: viewModel.interfaceMode) }
    }
}
