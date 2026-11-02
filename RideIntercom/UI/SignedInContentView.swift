import SwiftUI

struct SignedInContentView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Call", systemImage: "phone", value: .call) {
                NavigationStack {
                    if viewModel.interfaceMode == .standard {
                        StandardCallView(viewModel: viewModel, selectedTab: $selectedTab)
                    } else {
                        CallEntryView(viewModel: viewModel, selectedTab: $selectedTab)
                    }
                }
            }.accessibilityIdentifier("callTab")
            Tab("Users", systemImage: "person.2", value: .users) {
                NavigationStack {
                    if viewModel.interfaceMode == .standard {
                        StandardUsersView(viewModel: viewModel, selectedTab: $selectedTab)
                    } else {
                        AdvancedUsersView(viewModel: viewModel, selectedTab: $selectedTab)
                    }
                }
            }.accessibilityIdentifier("usersTab")
            Tab("Groups", systemImage: "person.3", value: .groups) {
                NavigationStack {
                    if viewModel.interfaceMode == .standard {
                        StandardGroupsView(viewModel: viewModel, selectedTab: $selectedTab)
                    } else {
                        AdvancedGroupsView(viewModel: viewModel, selectedTab: $selectedTab)
                    }
                }
            }.accessibilityIdentifier("groupsTab")
            if viewModel.interfaceMode == .advanced {
                Tab("Diagnostics", systemImage: "gauge", value: .diagnostics) {
                    NavigationStack { DiagnosticsView(viewModel: viewModel).navigationTitle("Diagnostics") }
                }.accessibilityIdentifier("diagnosticsTab")
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack { SettingsView(viewModel: viewModel).navigationTitle("Settings") }
                    .id(viewModel.interfaceMode)
            }.accessibilityIdentifier("settingsTab")
        }
        .sheet(item: $viewModel.contactInvitationPresentation) { presentation in
            switch presentation {
            case .sharing(let id):
                ContactInvitationSheet(viewModel: viewModel, invitationID: id)
            case .accepting(let preview):
                ContactInvitationAcceptanceView(viewModel: viewModel, preview: preview) { selectedTab = .users }
            }
        }
        .onChange(of: selectedTab) { previous, current in
            if previous == .users && current != .users { viewModel.stopContactInvitationSession() }
        }
        .onDisappear { viewModel.stopContactInvitationSession() }
        .task { await viewModel.storeAccess.start() }
        .task { await viewModel.notifications.refresh() }
        .onChange(of: viewModel.interfaceMode) { _, mode in selectedTab = selectedTab.available(in: mode) }
        .onAppear { selectedTab = selectedTab.available(in: viewModel.interfaceMode) }
    }
}
