import SwiftUI

struct SavedUsersView: View {
    @Bindable var viewModel: IntercomViewModel
    var groupID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @State private var groupName = "Talk Group"
    @State private var editingUser: SavedUser?

    private var users: [SavedUser] { viewModel.availableUsers(for: groupID) }
    private var memberCount: Int {
        (viewModel.groups.first { $0.id == groupID }?.members.count ?? 1)
        + users.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.memberIDs.count }
    }

    var body: some View {
        NavigationStack {
            Form {
                if groupID == nil {
                    Section("New Group") {
                        TextField("Group name", text: $groupName)
                            .accessibilityIdentifier("savedUsersGroupNameField")
                    }
                }
                Section {
                    if users.isEmpty {
                        Text("People you invite directly, or whose invitations you accept, are saved here. Deleting a group does not remove them.")
                    }
                    ForEach(users) { user in
                        HStack {
                            Toggle(user.resolvedDisplayName, isOn: Binding(
                                get: { selection.contains(user.id) },
                                set: { if $0 { selection.insert(user.id) } else { selection.remove(user.id) } }
                            ))
                            .accessibilityIdentifier("selectUser-\(user.id)")
                            Button { editingUser = user } label: {
                                Label("Edit \(user.resolvedDisplayName)", systemImage: "pencil")
                                    .labelStyle(.iconOnly)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("editUser-\(user.id)")
                        }
                        .appDeleteActions {
                            if viewModel.removeSavedUser(user.id) { selection.remove(user.id) }
                        }
                    }
                } header: {
                    Text("Saved Users")
                } footer: {
                    Text("Share the group's invitation so the selected users can join. Selecting a user does not call or notify them. Deleting a saved user keeps existing groups and calls.")
                }
                Section {
                    Text("\(memberCount) of 8 members including you")
                    if let message = viewModel.groupErrorMessage {
                        Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger)
                            .accessibilityIdentifier("savedUsersErrorLabel")
                    }
                }
            }
            .navigationTitle(LocalizedStringKey(groupID == nil ? "Saved Users" : "Add Saved Users"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("closeSavedUsersButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey(groupID == nil ? "Create Group" : "Add Users")) {
                        let saved = if let groupID {
                            viewModel.addSavedUsers(selection, to: groupID)
                        } else {
                            viewModel.createTalkGroup(name: groupName, userIDs: selection)
                        }
                        if saved { dismiss() }
                    }
                    .disabled(!viewModel.canEditSavedGroups || memberCount > 8 || (groupID != nil && selection.isEmpty)
                              || (groupID == nil && (!IntercomGroup.isValidName(groupName) || groupName.contains("|"))))
                    .accessibilityIdentifier("saveUserSelectionButton")
                }
            }
            .sheet(item: $editingUser) { user in
                SavedUserNameView(viewModel: viewModel, user: user)
            }
        }
        .frame(minWidth: 300, idealWidth: 480, minHeight: 360)
    }
}

struct SavedUserNameView: View {
    @Bindable var viewModel: IntercomViewModel
    let user: SavedUser
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(viewModel: IntercomViewModel, user: SavedUser) {
        self.viewModel = viewModel; self.user = user
        _name = State(initialValue: user.resolvedDisplayName)
    }

    private var currentUser: SavedUser { viewModel.savedUsers.first { $0.id == user.id } ?? user }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name on this device", text: $name).accessibilityIdentifier("savedUserNameField")
                LabeledContent("Name shared by this person", value: currentUser.displayName)
                    .accessibilityIdentifier("savedUserOriginalName")
                Button("Use Shared Name") {
                    if viewModel.resetSavedUserName(user.id) { dismiss() }
                }
                .accessibilityIdentifier("resetUserNameButton")
                Text("Your name for this person stays on this device. Use Shared Name removes your edit and follows their name updates.").font(.footnote)
                if let message = viewModel.groupErrorMessage { Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger) }
            }
            .navigationTitle("Edit User")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.renameSavedUser(user.id, displayName: name) { dismiss() }
                    }
                    .disabled(!IntercomGroup.isValidName(name))
                    .accessibilityIdentifier("saveUserNameButton")
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 480, minHeight: 280)
    }
}
