import SwiftUI

struct StandardUsersView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var editingUser: SavedUser?

    var body: some View {
        List {
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
            StandardStorageSection(viewModel: viewModel)
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
                        Button { editingUser = user } label: { Label("Edit Name", systemImage: "pencil") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                    }
                    .appDeleteActions { _ = viewModel.removeSavedUser(user.id) }
                }
            } footer: {
                Text("Only direct invitations save a person here. Removing a saved user keeps your existing groups and calls.")
            }
            StandardErrorSection(viewModel: viewModel)
        }
        .navigationTitle("Users")
        .accessibilityIdentifier("standardUsersList")
        .sheet(item: $editingUser) { user in SavedUserNameView(viewModel: viewModel, user: user) }
    }
}

struct StandardGroupsView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var createsGroup = false
    @State private var previousSelection: UUID?

    var body: some View {
        List {
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
            StandardStorageSection(viewModel: viewModel)
            Section {
                if viewModel.regularGroups.isEmpty {
                    ContentUnavailableView("No Groups Yet", systemImage: "person.3", description: Text("Create a group or open an invitation from a friend."))
                }
                ForEach(viewModel.regularGroups) { group in
                    Button {
                        viewModel.selectGroup(group, connectIfIdle: false)
                        selectedTab = .call
                    } label: { Label(group.name, systemImage: "person.3") }
                    .accessibilityIdentifier("standardGroup-\(group.id)")
                    .appDeleteActions { viewModel.deleteGroup(group.id) }
                }
            }
            StandardErrorSection(viewModel: viewModel)
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
        .accessibilityIdentifier("standardGroupsList")
    }
}
