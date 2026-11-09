import SwiftUI

/// Choosing saved users for a new group or for an existing one. Each mode has its own selection
/// screen; both share the selection's data and operations and the invitation step that follows.
struct SavedUsersView: View {
    @Bindable var viewModel: IntercomViewModel
    var groupID: UUID?
    @Environment(\.dismiss) private var dismiss
    /// Set once saved users were committed to this group. Adding them only lists
    /// them here; their devices get the group key from the shared invitation.
    @State private var invitationGroupID: UUID?
    private var invitationGroup: IntercomGroup? { viewModel.groups.first { $0.id == invitationGroupID } }

    var body: some View {
        NavigationStack {
            if let group = invitationGroup {
                invitationStep(group)
            } else if viewModel.interfaceMode == .advanced {
                AdvancedSavedUsersSelection(viewModel: viewModel, groupID: groupID, onSaved: finish)
            } else {
                StandardMemberSelection(viewModel: viewModel, groupID: groupID, onSaved: finish)
            }
        }
        // A group removed during the invitation step has nothing left to share.
        .onChange(of: invitationGroupID != nil && invitationGroup == nil) { _, removed in if removed { dismiss() } }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 360)
        #endif
    }

    /// Creating selects the new group. Only added people need the invitation.
    private func finish(_ addedTo: UUID?) {
        if let addedTo { invitationGroupID = addedTo } else { dismiss() }
    }

    /// Until saved users receive the group automatically, the added people get it by a shared link.
    private func invitationStep(_ group: IntercomGroup) -> some View {
        Form {
            Section {
                Text("Send the group invitation to the people you added. When they open it, \(group.name) and its key are added on their device, and you can talk nearby without the Internet.")
                    .accessibilityIdentifier("sendGroupInvitationMessage")
                CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "addedUsersInviteButton", bindsToGroup: true)
            } footer: {
                Text("Adding people only lists them on this device. You can send the invitation later from Invite.")
            }
        }
        .navigationTitle(LocalizedStringKey("Send Invitation"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("finishAddingUsersButton")
            }
        }
    }
}

/// The selection's data and its save operation, shared by both modes' selection screens.
struct MemberSelection {
    let viewModel: IntercomViewModel
    let groupID: UUID?
    var selected: Set<UUID> = []
    var typedName = ""

    var users: [SavedUser] { viewModel.availableUsers(for: groupID) }

    /// "Haruka, Kenta and Yu" from the people chosen so far, in the list's order.
    var suggestedName: String? {
        let names = users.filter { selected.contains($0.id) }.map(\.resolvedDisplayName)
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
    }

    var groupName: String {
        let typed = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (suggestedName ?? "") : typed
    }

    var memberCount: Int {
        (viewModel.groups.first { $0.id == groupID }?.members.count ?? 1)
        + users.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.memberIDs.count }
    }

    var canSave: Bool {
        viewModel.canEditSavedGroups && memberCount <= IntercomGroup.maximumMemberCount
            && (groupID == nil ? IntercomGroup.isValidName(groupName) && !groupName.contains("|") : !selected.isEmpty)
    }

    mutating func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Saves, then returns the group the people were added to, or nil when nobody was added.
    /// Returns `.none` when saving failed.
    func save() -> UUID?? {
        let saved = if let groupID { viewModel.addSavedUsers(selected, to: groupID) }
                    else { viewModel.createTalkGroup(name: groupName, userIDs: selected) }
        guard saved else { return .none }
        return .some(selected.isEmpty ? nil : groupID ?? viewModel.selectedGroup?.id)
    }
}

struct SavedUserNameView: View {
    @Bindable var viewModel: IntercomViewModel
    let user: SavedUser
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var confirmsDelete = false

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
                CallNotificationContactSection(viewModel: viewModel, userID: user.id)
                if let call = viewModel.existingDirectCall(for: user.id), viewModel.canShareGroup(call.id) {
                    Section {
                        CallInvitationButton(viewModel: viewModel, group: call, accessibilityIdentifier: "userSettingsInviteButton",
                                             bindsToGroup: true)
                    }
                }
                Section {
                    Button("Delete User", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                        .disabled(!viewModel.canEditSavedGroups)
                        .accessibilityIdentifier("deleteUserButton")
                }
                if let message = viewModel.groupErrorMessage { Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger) }
            }
            .formStyle(.grouped)
            .navigationTitle("User Settings")
            .accessibilityIdentifier("userSettingsView")
            .alert("Delete User?", isPresented: $confirmsDelete) {
                Button("Delete User", role: .destructive) {
                    if viewModel.removeSavedUser(user.id) { dismiss() }
                }
                .accessibilityIdentifier("confirmDeleteUserButton")
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Groups and a call in progress are kept.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("closeUserSettingsButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.renameSavedUser(user.id, displayName: name) { dismiss() }
                    }
                    .disabled(!IntercomGroup.isValidName(name))
                    .accessibilityIdentifier("saveUserNameButton")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 280)
        #endif
    }
}
