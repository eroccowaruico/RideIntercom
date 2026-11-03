import SwiftUI

struct AdvancedUsersView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var settings: DestinationSettingsTarget?
    @State private var pendingSwitch: CallDestination?

    var body: some View {
        List {
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
            RecentCallSection(viewModel: viewModel, pendingSwitch: $pendingSwitch) { selectedTab = .call }
            CallStorageSection(viewModel: viewModel)
            PendingContactInvitationsSection(viewModel: viewModel)
            Section {
                if viewModel.savedRemoteUsers.isEmpty {
                    ContentUnavailableView("No Saved Users", systemImage: "person.2",
                        description: Text("Invite someone, or accept an invitation to save each other."))
                }
                ForEach(viewModel.savedRemoteUsers) { user in
                    Button {
                        viewModel.open(.user(user.id), pending: $pendingSwitch) { selectedTab = .call }
                    } label: {
                        DirectoryRowLabel(title: user.resolvedDisplayName, isGroup: false,
                                          status: viewModel.isInCall(with: .user(user.id)) ? viewModel.callStatus(for: viewModel.activeGroupID) : nil)
                    }
                    .directoryRowButtonStyle()
                    .accessibilityIdentifier("standardUser-\(user.id)")
                    .destinationRowActions("User Settings", settings: { settings = .user(user.id) }) {
                        _ = viewModel.removeSavedUser(user.id)
                    }
                }
            } footer: {
                Text("Only direct invitations save a person here. Removing a saved user keeps your existing groups and calls.")
            }
            CallErrorSection(viewModel: viewModel)
        }
        .navigationTitle("Users")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Invite Someone", systemImage: "plus") { viewModel.beginContactInvitationPresentation() }
                    .disabled(!viewModel.canEditSavedGroups)
                    .accessibilityIdentifier("inviteContactButton")
            }
        }
        .accessibilityIdentifier("standardUsersList")
        .destinationSettingsSheet($settings, viewModel: viewModel)
        .switchCallConfirmation($pendingSwitch, viewModel: viewModel) { selectedTab = .call }
    }
}

struct AdvancedGroupsView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var createsGroup = false
    @State private var previousSelection: UUID?
    @State private var settings: DestinationSettingsTarget?
    @State private var pendingSwitch: CallDestination?

    var body: some View {
        List {
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
            CallStorageSection(viewModel: viewModel)
            Section {
                if viewModel.regularGroups.isEmpty {
                    ContentUnavailableView("No Groups Yet", systemImage: "person.3", description: Text("Create a group or open an invitation from a friend."))
                }
                ForEach(viewModel.regularGroups) { group in
                    Button {
                        viewModel.open(.group(group.id), pending: $pendingSwitch) { selectedTab = .call }
                    } label: {
                        DirectoryGroupLabel(viewModel: viewModel, group: group)
                    }
                    .directoryRowButtonStyle()
                    .accessibilityIdentifier("standardGroup-\(group.id)")
                    .destinationRowActions("Group Settings", settings: { settings = .group(group.id) }) {
                        viewModel.deleteGroup(group.id)
                    }
                }
            }
            CallErrorSection(viewModel: viewModel)
        }
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Group", systemImage: "plus") { previousSelection = viewModel.selectedGroup?.id; createsGroup = true }
                    .disabled(!viewModel.canEditSavedGroups).accessibilityIdentifier("standardCreateGroupButton")
            }
        }
        .sheet(isPresented: $createsGroup, onDismiss: {
            if viewModel.selectedGroup?.id != previousSelection { selectedTab = .call }
        }) { SavedUsersView(viewModel: viewModel) }
        .destinationSettingsSheet($settings, viewModel: viewModel)
        .switchCallConfirmation($pendingSwitch, viewModel: viewModel) { selectedTab = .call }
        .accessibilityIdentifier("standardGroupsList")
    }
}
