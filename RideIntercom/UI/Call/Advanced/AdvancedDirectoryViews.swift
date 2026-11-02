import SwiftUI

struct AdvancedUsersView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var editingUser: SavedUser?
    @State private var managingCall: GroupManagementSelection?

    var body: some View {
        List {
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
            CallStorageSection(viewModel: viewModel)
            Section {
                if viewModel.savedRemoteUsers.isEmpty {
                    ContentUnavailableView("No Saved Users", systemImage: "person.2",
                        description: Text("Share a group invitation or accept someone's invitation to save each other."))
                }
                ForEach(viewModel.savedRemoteUsers) { user in
                    HStack {
                        Button {
                            if viewModel.selectUser(user.id, connectIfIdle: false) { selectedTab = .call }
                        } label: { Label(user.resolvedDisplayName, systemImage: "person.crop.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("standardUser-\(user.id)")
                        Spacer()
                        Button {
                            if viewModel.selectUser(user.id, connectIfIdle: false), let group = viewModel.selectedGroup, group.kind == .direct {
                                managingCall = .init(groupID: group.id, kind: .direct, userID: user.id)
                            }
                        } label: { Label("Manage", systemImage: "info.circle") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Manage \(user.resolvedDisplayName)")
                            .accessibilityIdentifier("manageUser-\(user.id)")
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
        .navigationTitle("Users")
        .accessibilityIdentifier("standardUsersList")
        .sheet(item: $editingUser) { user in SavedUserNameView(viewModel: viewModel, user: user) }
        .sheet(item: $managingCall) { selection in GroupManagementView(viewModel: viewModel, selection: selection) }
    }
}

struct AdvancedGroupsView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var createsGroup = false
    @State private var previousSelection: UUID?
    @State private var managingCall: GroupManagementSelection?

    var body: some View {
        List {
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
            CallStorageSection(viewModel: viewModel)
            Section {
                if viewModel.regularGroups.isEmpty {
                    ContentUnavailableView("No Groups Yet", systemImage: "person.3", description: Text("Create a group or open an invitation from a friend."))
                }
                ForEach(viewModel.regularGroups) { group in
                    HStack {
                        Button {
                            viewModel.selectGroup(group, connectIfIdle: false)
                            selectedTab = .call
                        } label: {
                            DirectoryGroupLabel(viewModel: viewModel, group: group)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("standardGroup-\(group.id)")
                        .buttonStyle(.borderless)
                        Button {
                            guard let current = viewModel.regularGroups.first(where: { $0.id == group.id }) else { return }
                            viewModel.selectGroup(current, connectIfIdle: false)
                            managingCall = .init(groupID: current.id, kind: .group)
                        } label: { Label("Manage", systemImage: "info.circle") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Manage \(group.name)")
                            .accessibilityIdentifier("manageGroup-\(group.id)")
                    }
                    .appDeleteActions { viewModel.deleteGroup(group.id) }
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
        .sheet(item: $managingCall) { selection in GroupManagementView(viewModel: viewModel, selection: selection) }
        .accessibilityIdentifier("standardGroupsList")
    }
}
