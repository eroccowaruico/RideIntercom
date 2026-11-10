import SwiftUI

struct SignedInContentView: View {
    @Bindable var viewModel: IntercomViewModel
    /// `.call` is not a tab: it opens the call over the last list tab.
    @Binding var selectedTab: AppTab
    @State private var listTab: AppTab = .users
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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
            // Standard shows Groups only when turned on in Advanced Settings for Developers.
            if viewModel.isGroupsTabVisible {
                Tab("Groups", systemImage: "person.3", value: .groups) {
                    NavigationStack {
                        if viewModel.interfaceMode == .standard {
                            StandardGroupsView(viewModel: viewModel, selectedTab: $selectedTab)
                        } else {
                            AdvancedGroupsView(viewModel: viewModel, selectedTab: $selectedTab)
                        }
                    }
                }.accessibilityIdentifier("groupsTab")
            }
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
        // A tab bar on iPhone, a sidebar on iPad and Mac (switchable on iPad).
        .tabViewStyle(.sidebarAdaptable)
        .inspector(isPresented: callPresentation(asSheet: false)) {
            CallPanel(viewModel: viewModel, selectedTab: $selectedTab) { selectedTab = listTab }
        }
        #if os(iOS)
        // On a compact width the call is a plain sheet. The inspector's own compact sheet with
        // the call's More menu in its toolbar crashed SwiftUI's glass rendering when the call was
        // reopened from the list (7 of 9 runs; 0 of 5 as a plain sheet, 2026-11-03).
        .sheet(isPresented: callPresentation(asSheet: true)) {
            CallPanel(viewModel: viewModel, selectedTab: $selectedTab) { selectedTab = listTab }
        }
        .tabViewBottomAccessory(isEnabled: showsAccessory) {
            CallAccessory(viewModel: viewModel, open: openLiveCall)
        }
        #else
        .toolbar {
            if showsAccessory {
                ToolbarItem {
                    // The call's name and state, as the iPhone's call accessory shows them.
                    Button(action: openLiveCall) { macCallLabel }
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("callAccessoryOpenButton")
                }
            }
        }
        #endif
        .onChange(of: selectedTab) { _, current in if current != .call { listTab = current } }
        // A one-to-one ring stops when they join or the call ends.
        .onChange(of: viewModel.callStatus(for: viewModel.activeGroupID)) { viewModel.settleDirectRing() }
        .onChange(of: viewModel.hasAnyActiveGroupConnection) { viewModel.settleDirectRing() }
        // Turning the tab off while it is shown returns to Users; calls and groups stay as they are.
        .onChange(of: viewModel.isGroupsTabVisible) { _, visible in
            guard !visible else { return }
            if listTab == .groups { listTab = .users }
            if selectedTab == .groups { selectedTab = .users }
        }
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
        // The call opens over the list, so only leaving the Users list stops its invitation session.
        .onChange(of: listTab) { previous, current in
            if previous == .users && current != .users { viewModel.stopContactInvitationSession() }
        }
        .onDisappear { viewModel.stopContactInvitationSession() }
        .task { await viewModel.storeAccess.start() }
        .task { await viewModel.notifications.refresh() }
        .onChange(of: viewModel.interfaceMode) { _, mode in selectedTab = selectedTab.available(in: mode) }
        .onAppear { selectedTab = selectedTab.available(in: viewModel.interfaceMode) }
    }

    /// The accessory always returns to the live call, even after another destination was shown.
    private func openLiveCall() {
        if let id = viewModel.activeGroupID, viewModel.selectedGroup?.id != id,
           let group = viewModel.groups.first(where: { $0.id == id }) {
            viewModel.selectGroup(group, connectIfIdle: false)
        }
        selectedTab = .call
    }

    private var tabSelection: Binding<AppTab> {
        Binding(get: { selectedTab == .call ? listTab : selectedTab }, set: { selectedTab = $0 })
    }

    private var showsCall: Binding<Bool> {
        Binding(get: { selectedTab == .call && viewModel.selectedGroup != nil },
                set: { if !$0 && selectedTab == .call { selectedTab = listTab } })
    }

    private func callPresentation(asSheet: Bool) -> Binding<Bool> {
        Binding(get: { showsCall.wrappedValue && usesCallSheet == asSheet }, set: { showsCall.wrappedValue = $0 })
    }

    private var usesCallSheet: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    #if os(macOS)
    @ViewBuilder private var macCallLabel: some View {
        if let id = viewModel.activeGroupID, let group = viewModel.groups.first(where: { $0.id == id }) {
            let status = viewModel.callStatus(for: id)
            Label {
                Text(verbatim: "\(viewModel.callTitle(for: group)) · \(String(localized: .init(stringLiteral: status.title)))")
            } icon: {
                CallStatusSymbol(status: status)
            }
        }
    }
    #endif

    private var showsAccessory: Bool { viewModel.hasAnyActiveGroupConnection && !showsCall.wrappedValue }

    private var needsName: Binding<Bool> {
        Binding(get: { viewModel.needsDisplayNameChoice }, set: { _ in })
    }
}
