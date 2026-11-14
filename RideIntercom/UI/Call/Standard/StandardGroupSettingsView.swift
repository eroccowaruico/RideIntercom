import SwiftUI

/// The group's name, You and the members (a tap opens a member, the swipe removes them), Invite Members, then
/// one red button last: Delete Group for whoever made it, Leave Group for everyone else.
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

    private var ownsGroup: Bool { viewModel.groupRepository.ownsGroup(groupID) }
    private var endsCall: Bool { viewModel.activeGroupID == groupID || viewModel.isActiveCall(.group(groupID)) }
    private var confirmationTitle: Text {
        let name = group?.name ?? ""
        return ownsGroup ? Text("Delete \(name)?") : Text("Leave \(name)?")
    }
    private var confirmationAction: LocalizedStringKey {
        switch (ownsGroup, endsCall) {
        case (true, true): "Disconnect and Delete"
        case (true, false): "Delete"
        case (false, true): "Disconnect and Leave"
        case (false, false): "Leave"
        }
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
                        // You come first, as in the call; your own row opens nothing.
                        HStack(spacing: AppSpacing.m) {
                            DestinationAvatar(isGroup: false, diameter: 28).accessibilityHidden(true)
                            Text("You")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("groupSettingsSelf")
                        ForEach(Array(group.members.dropFirst())) { member in
                            // The tap opens the member's own page; the swipe removes them.
                            Button { editingMember = member } label: {
                                HStack(spacing: AppSpacing.m) {
                                    DestinationAvatar(isGroup: false, diameter: 28).accessibilityHidden(true)
                                    Text(verbatim: member.resolvedDisplayName).lineLimit(2)
                                    Spacer()
                                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                                }
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("groupSettingsMember-\(member.id)")
                            .standardMemberRowActions(canRemove: viewModel.canManageRegularGroups, pending: $pendingRemoval,
                                                      name: member.resolvedDisplayName) {
                                viewModel.removeMember(member.id, from: groupID)
                            }
                        }
                        // Only those with the usage right invite; others see no invite row.
                        if viewModel.canManageRegularGroups {
                        Button { invitingMembers = true } label: {
                            HStack(spacing: AppSpacing.m) {
                                PendingAvatar(diameter: 28)
                                Text("Invite Members")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.availableUsers(for: groupID).isEmpty
                                  || group.members.count >= IntercomGroup.maximumMemberCount)
                        .accessibilityIdentifier("groupSettingsAddMembersButton")
                        }
                    } header: {
                        Text("Members")
                    }
                    // One last button: whoever made the group deletes it; everyone else leaves it.
                    Section {
                        if ownsGroup {
                            Button("Delete Group", role: .destructive) { confirmsDelete = true }
                                .disabled(!viewModel.canEditSavedGroups)
                                .accessibilityIdentifier("deleteGroupButton")
                        } else {
                            Button("Leave Group", role: .destructive) { confirmsDelete = true }
                                .accessibilityIdentifier("leaveGroupButton")
                        }
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
            .alert(confirmationTitle, isPresented: $confirmsDelete) {
                Button(confirmationAction, role: .destructive) {
                    viewModel.deleteGroup(groupID)
                    dismiss()
                }
                .accessibilityIdentifier(ownsGroup ? "confirmDeleteGroupButton" : "confirmLeaveGroupButton")
                Button("Cancel", role: .cancel) { }
            } message: {
                if endsCall { Text("The current connection ends.") }
            }
            .sheet(isPresented: $invitingMembers) { SavedUsersView(viewModel: viewModel, groupID: groupID) }
            .sheet(item: $editingMember) { member in
                // The member's own page ends with removing them, for whoever can edit the group.
                StandardGroupMemberView(viewModel: viewModel, groupID: groupID, member: member,
                                        remove: viewModel.canManageRegularGroups ? { viewModel.removeMember(member.id, from: groupID) } : nil)
            }
            .memberRemoveConfirmation($pendingRemoval)
            .accessibilityIdentifier("groupSettingsView")
        }
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400)
        #endif
    }
}
