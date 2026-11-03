import SwiftUI

struct SignedInContentView: View {
    @Bindable var viewModel: IntercomViewModel
    /// `.call` is not a tab: it opens the call over the last list tab.
    @Binding var selectedTab: AppTab
    @State private var listTab: AppTab = .users

    var body: some View {
        TabView(selection: tabSelection) {
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
        .inspector(isPresented: showsCall) {
            CallPanel(viewModel: viewModel, selectedTab: $selectedTab) { selectedTab = listTab }
        }
        #if os(iOS)
        .tabViewBottomAccessory(isEnabled: showsAccessory) {
            CallAccessory(viewModel: viewModel) { selectedTab = .call }
        }
        #else
        .toolbar {
            if showsAccessory {
                ToolbarItem {
                    Button("Current Call", systemImage: "phone.fill") { selectedTab = .call }
                        .accessibilityIdentifier("callAccessoryOpenButton")
                }
            }
        }
        #endif
        .onChange(of: selectedTab) { _, current in if current != .call { listTab = current } }
        // Ending the call returns to the list; there is no screen just for reconnecting.
        .onChange(of: viewModel.hasAnyActiveGroupConnection) { wasActive, isActive in
            if wasActive && !isActive && selectedTab == .call { selectedTab = listTab }
        }
        .sheet(item: $viewModel.contactInvitationPresentation) { presentation in
            switch presentation {
            case .sharing(let id):
                ContactInvitationSheet(viewModel: viewModel, invitationID: id)
            case .accepting(let preview):
                ContactInvitationAcceptanceView(viewModel: viewModel, preview: preview) { selectedTab = .users }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: needsName) { DisplayNameChoiceView(viewModel: viewModel) }
        #else
        .sheet(isPresented: needsName) { DisplayNameChoiceView(viewModel: viewModel) }
        #endif
        .onChange(of: selectedTab) { previous, current in
            if previous == .users && current != .users { viewModel.stopContactInvitationSession() }
        }
        .onDisappear { viewModel.stopContactInvitationSession() }
        .task { await viewModel.storeAccess.start() }
        .task { await viewModel.notifications.refresh() }
        .onChange(of: viewModel.interfaceMode) { _, mode in selectedTab = selectedTab.available(in: mode) }
        .onAppear { selectedTab = selectedTab.available(in: viewModel.interfaceMode) }
    }

    private var tabSelection: Binding<AppTab> {
        Binding(get: { selectedTab == .call ? listTab : selectedTab }, set: { selectedTab = $0 })
    }

    private var showsCall: Binding<Bool> {
        Binding(get: { selectedTab == .call && viewModel.selectedGroup != nil },
                set: { if !$0 && selectedTab == .call { selectedTab = listTab } })
    }

    private var showsAccessory: Bool { viewModel.hasAnyActiveGroupConnection && !showsCall.wrappedValue }

    private var needsName: Binding<Bool> {
        Binding(get: { viewModel.needsDisplayNameChoice }, set: { _ in })
    }
}
