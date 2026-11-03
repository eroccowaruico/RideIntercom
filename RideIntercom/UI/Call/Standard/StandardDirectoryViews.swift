import SwiftUI

struct StandardUsersView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var editingUser: SavedUser?
    @State private var pendingSwitch: CallDestination?

    var body: some View {
        List {
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
            CallStorageSection(viewModel: viewModel)
            PendingContactInvitationsSection(viewModel: viewModel)
            Section {
                if viewModel.savedRemoteUsers.isEmpty {
                    ContentUnavailableView("No Saved Users", systemImage: "person.2",
                        description: Text("Invite someone, or accept an invitation to save each other."))
                }
                ForEach(viewModel.savedRemoteUsers) { user in
                    HStack {
                        Button {
                            viewModel.open(.user(user.id), pending: $pendingSwitch) { selectedTab = .call }
                        } label: {
                            Label { Text(user.resolvedDisplayName) } icon: {
                                DestinationAvatar(isGroup: false)
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("standardUser-\(user.id)")
                        Spacer()
                        Button { editingUser = user } label: { Label("Edit Name", systemImage: "pencil") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                    }
                    .appDeleteActions { _ = viewModel.removeSavedUser(user.id) }
                }
            } footer: {
                Text("Only direct invitations save a person here. Removing a saved user keeps your existing groups and calls.")
            }
            CallErrorSection(viewModel: viewModel)
        }
        .scrollContentBackground(.hidden)
        .background(AppColorPalette.standardScreenBackground)
        .navigationTitle("Users")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Invite Someone", systemImage: "plus") { viewModel.beginContactInvitationPresentation() }
                    .disabled(!viewModel.canEditSavedGroups)
                    .accessibilityIdentifier("inviteContactButton")
            }
        }
        .accessibilityIdentifier("standardUsersList")
        .sheet(item: $editingUser) { user in SavedUserNameView(viewModel: viewModel, user: user) }
        .switchCallConfirmation($pendingSwitch, viewModel: viewModel) { selectedTab = .call }
    }
}

struct StandardGroupsView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var createsGroup = false
    @State private var previousSelection: UUID?
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
                    .accessibilityIdentifier("standardGroup-\(group.id)")
                    .appDeleteActions { viewModel.deleteGroup(group.id) }
                }
            }
            CallErrorSection(viewModel: viewModel)
        }
        .scrollContentBackground(.hidden)
        .background(AppColorPalette.standardScreenBackground)
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
        .switchCallConfirmation($pendingSwitch, viewModel: viewModel) { selectedTab = .call }
        .accessibilityIdentifier("standardGroupsList")
    }
}
