import SwiftUI

/// Advanced's group settings: name, members with their row actions, the link invitation and Delete Group.
struct AdvancedGroupSettingsView: View {
    let viewModel: IntercomViewModel
    let groupID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name: String?
    @State private var addingUsers = false
    @State private var editingMember: GroupMember?
    @State private var confirmsDelete = false
    @State private var pendingRemoval: PendingMemberRemoval?

    private var group: IntercomGroup? { viewModel.groups.first { $0.id == groupID && $0.kind == .group } }

    var body: some View {
        NavigationStack {
            Form {
                if let group {
                    Section("Name") {
                        TextField("Group name", text: Binding(get: { name ?? group.name }, set: { name = $0 }))
                            .accessibilityIdentifier("groupSettingsNameField")
                    }
                    Section {
                        ForEach(Array(group.members.dropFirst())) { member in
                            Label { Text(member.resolvedDisplayName) } icon: { DestinationAvatar(isGroup: false, diameter: 28) }
                                .advancedMemberRowActions(edit: { editingMember = member }, pending: $pendingRemoval,
                                                  name: member.resolvedDisplayName) {
                                    viewModel.removeMember(member.id, from: groupID)
                                }
                        }
                        Button("Add Members", systemImage: "person.badge.plus") { addingUsers = true }
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
                    if viewModel.canShareGroup(groupID) {
                        Section {
                            CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "groupSettingsInviteButton",
                                                 bindsToGroup: true)
                        }
                    }
                    Section {
                        Button("Delete Group", systemImage: "trash", role: .destructive) { confirmsDelete = true }
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
            .navigationTitle("Group Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("closeGroupSettingsButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let name, name != group?.name, !viewModel.renameGroup(groupID, to: name) { return }
                        dismiss()
                    }
                    .disabled(group == nil || !(name.map { IntercomGroup.isValidName($0) && !$0.contains("|") } ?? true))
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
            .sheet(isPresented: $addingUsers) { SavedUsersView(viewModel: viewModel, groupID: groupID) }
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
