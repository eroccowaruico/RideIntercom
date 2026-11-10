import SwiftUI

/// Advanced's selection of saved users: each row's toggle, rename and delete.
struct AdvancedSavedUsersSelection: View {
    @Bindable var viewModel: IntercomViewModel
    let groupID: UUID?
    let onSaved: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: MemberSelection
    @State private var editingUser: SavedUser?

    init(viewModel: IntercomViewModel, groupID: UUID?, onSaved: @escaping (UUID?) -> Void) {
        self.viewModel = viewModel
        self.groupID = groupID
        self.onSaved = onSaved
        _selection = State(initialValue: MemberSelection(viewModel: viewModel, groupID: groupID))
    }

    var body: some View {
        Form {
            if groupID == nil {
                Section("Group name") {
                    TextField("Group name", text: $selection.typedName, prompt: selection.suggestedName.map { Text(verbatim: $0) })
                        .accessibilityIdentifier("savedUsersGroupNameField")
                }
            }
            Section {
                if selection.users.isEmpty {
                    Text("People you invite directly, or whose invitations you accept, are saved here. Deleting a group does not remove them.")
                }
                ForEach(selection.users) { user in
                    HStack {
                        Toggle(user.resolvedDisplayName, isOn: Binding(
                            get: { selection.selected.contains(user.id) },
                            set: { _ in selection.toggle(user.id) }
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
                        if viewModel.removeSavedUser(user.id) { selection.selected.remove(user.id) }
                    }
                }
            } header: {
                Text("Saved Users")
            } footer: {
                Text("After you add them, send the group invitation so they can join. Selecting a user does not call or notify them. Deleting a saved user keeps existing groups and calls.")
            }
            Section {
                Text("\(selection.memberCount) of 8 members including you")
                if let message = viewModel.groupErrorMessage {
                    Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger)
                        .accessibilityIdentifier("savedUsersErrorLabel")
                }
            }
        }
        .screenBackground(AppColorPalette.listScreenBackground)
        .navigationTitle(LocalizedStringKey(groupID == nil ? "New Group" : "Invite Members"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.accessibilityIdentifier("closeSavedUsersButton")
            }
            ToolbarItem(placement: .confirmationAction) {
                // A new group connects at once when no other call is live, so the button says so.
                Button(LocalizedStringKey(groupID != nil ? "Add Users"
                                          : viewModel.hasAnyActiveGroupConnection ? "Create Group" : "Create and Connect")) {
                    if case .some(let added) = selection.save() { onSaved(added) }
                }
                .disabled(!selection.canSave)
                .accessibilityIdentifier("saveUserSelectionButton")
            }
        }
        .sheet(item: $editingUser) { user in
            AdvancedUserSettingsView(viewModel: viewModel, user: user)
        }
    }
}
