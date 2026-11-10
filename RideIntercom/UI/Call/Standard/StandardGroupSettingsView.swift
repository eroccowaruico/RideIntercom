import SwiftUI

/// The group's name, its members and Invite Members below them, then Delete Group last in red.
/// Renaming and removing a member stay on the row's long press and swipe, as the footer says.
struct StandardGroupSettingsView: View {
    let viewModel: IntercomViewModel
    let groupID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name: String?
    @State private var invitingMembers = false
    @State private var editingMember: GroupMember?
    @State private var confirmsDelete = false
    @State private var pendingRemoval: PendingMemberRemoval?

    private var group: IntercomGroup? { viewModel.groups.first { $0.id == groupID && $0.kind == .group } }
    /// The name made from the members, as when the group was created.
    private var membersName: String {
        (group?.members.dropFirst().map(\.resolvedDisplayName) ?? []).formatted(.list(type: .and))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let group {
                    Section("Name") {
                        TextField("Group name", text: Binding(get: { name ?? group.name }, set: { name = $0 }),
                                  prompt: Text(verbatim: membersName))
                            .accessibilityIdentifier("groupSettingsNameField")
                    }
                    Section {
                        ForEach(Array(group.members.dropFirst())) { member in
                            HStack(spacing: AppSpacing.m) {
                                DestinationAvatar(isGroup: false, diameter: 28).accessibilityHidden(true)
                                Text(verbatim: member.resolvedDisplayName).lineLimit(2)
                            }
                            .frame(minHeight: 44)
                            .standardMemberRowActions(edit: { editingMember = member }, pending: $pendingRemoval,
                                                      name: member.resolvedDisplayName) {
                                viewModel.removeMember(member.id, from: groupID)
                            }
                        }
                        Button { invitingMembers = true } label: {
                            HStack(spacing: AppSpacing.m) {
                                PendingAvatar(diameter: 28)
                                Text("Invite Members")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!viewModel.canEditSavedGroups || viewModel.availableUsers(for: groupID).isEmpty
                                  || group.members.count >= IntercomGroup.maximumMemberCount)
                        .accessibilityIdentifier("groupSettingsAddMembersButton")
                    } header: {
                        Text("Members")
                    } footer: {
                        #if os(macOS)
                        Text("Control-click a member to rename or remove them.")
                        #else
                        Text("Touch and hold a member to rename or remove them.")
                        #endif
                    }
                    // Temporary: the only way to bring in someone who is not yet one of your users,
                    // until Invite Members can invite new people (see the backlog).
                    if viewModel.canShareGroup(groupID) {
                        Section {
                            CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "groupSettingsInviteButton",
                                                 bindsToGroup: true)
                        }
                    }
                    Section {
                        Button("Delete Group", role: .destructive) { confirmsDelete = true }
                            .disabled(!viewModel.canEditSavedGroups)
                            .accessibilityIdentifier("deleteGroupButton")
                    }
                    if let message = viewModel.groupErrorMessage {
                        Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger)
                            .accessibilityIdentifier("groupSettingsError")
                    }
                } else {
                    ContentUnavailableView("This group is no longer available.", systemImage: "person.3")
                }
            }
            .formStyle(.grouped)
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle("Group Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("closeGroupSettingsButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // An emptied name saves the name made from the members.
                    Button("Done") {
                        let typed = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        let saved = typed?.isEmpty == true ? membersName : typed
                        if let saved, saved != group?.name, !viewModel.renameGroup(groupID, to: saved) { return }
                        dismiss()
                    }
                    .disabled(group == nil || name?.contains("|") == true || (name?.isEmpty == true && membersName.isEmpty))
                    .accessibilityIdentifier("saveGroupSettingsButton")
                }
            }
            .alert("Delete Group?", isPresented: $confirmsDelete) {
                Button("Delete Group", role: .destructive) {
                    viewModel.deleteGroup(groupID)
                    dismiss()
                }
                .accessibilityIdentifier("confirmDeleteGroupButton")
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The group is removed from this device. If it is in a call, the call ends.")
            }
            .sheet(isPresented: $invitingMembers) { SavedUsersView(viewModel: viewModel, groupID: groupID) }
            .sheet(item: $editingMember) { member in
                GroupMemberNameView(viewModel: viewModel, groupID: groupID, member: member)
            }
            .memberRemoveConfirmation($pendingRemoval)
            .accessibilityIdentifier("groupSettingsView")
        }
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400)
        #endif
    }
}
