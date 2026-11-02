import SwiftUI

struct GroupManagementSelection: Identifiable {
    let groupID: UUID
    let kind: IntercomGroup.Kind
    var userID: UUID?
    var id: UUID { groupID }
}

struct GroupManagementView: View {
    let viewModel: IntercomViewModel
    let selection: GroupManagementSelection
    @Environment(\.dismiss) private var dismiss
    @State private var addingUsers = false
    @State private var editingMember: ManagementMemberSelection?
    @State private var editingUser: SavedUser?

    private var group: IntercomGroup? {
        guard viewModel.selectedGroup?.id == selection.groupID else { return nil }
        guard let group = viewModel.groups.first(where: { $0.id == selection.groupID && $0.kind == selection.kind }) else { return nil }
        if let userID = selection.userID, !viewModel.savedRemoteUsers.contains(where: { $0.id == userID }) { return nil }
        return group
    }

    private var groupIsValid: Bool { group != nil }

    var body: some View {
        NavigationStack {
            List {
                if let group {
                    if viewModel.canShareSelectedGroup {
                        Section { CallInvitationButton(viewModel: viewModel, group: group) }
                    }
                    if group.kind == .group {
                        Section("Participants") {
                            ForEach(Array(group.members.dropFirst())) { member in
                                Button {
                                    guard let current = self.group?.members.first(where: { $0.id == member.id }) else { return }
                                    editingMember = .init(member: current)
                                } label: {
                                    Label(member.resolvedDisplayName, systemImage: "pencil")
                                }
                                .appDeleteActions {
                                    guard self.group?.members.contains(where: { $0.id == member.id }) == true else { return }
                                    viewModel.removeMember(member.id, from: selection.groupID)
                                }
                            }
                            Button("Add Saved Users", systemImage: "person.badge.plus") {
                                guard groupIsValid else { return }
                                addingUsers = true
                            }
                                .disabled(!viewModel.canEditSavedGroups || viewModel.availableUsers(for: selection.groupID).isEmpty
                                          || group.members.count >= IntercomGroup.maximumMemberCount)
                                .accessibilityIdentifier("addSavedUsersButton")
                        }
                    } else if let userID = selection.userID,
                              let user = viewModel.savedRemoteUsers.first(where: { $0.id == userID }) {
                        Section {
                            Button("Edit Name", systemImage: "pencil") {
                                guard groupIsValid, let current = viewModel.savedRemoteUsers.first(where: { $0.id == user.id }) else { return }
                                editingUser = current
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("This group is no longer available. Return to the group list.", systemImage: "person.3")
                }
                CallErrorSection(viewModel: viewModel)
            }
            .navigationTitle(group.map(viewModel.callTitle) ?? "Call")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("closeGroupManagementButton")
                }
            }
            .accessibilityIdentifier("groupManagementView")
            .onChange(of: groupIsValid) { _, valid in
                if !valid {
                    addingUsers = false
                    editingMember = nil
                    editingUser = nil
                }
            }
            .sheet(isPresented: $addingUsers) { SavedUsersView(viewModel: viewModel, groupID: selection.groupID) }
            .sheet(item: $editingMember) { item in
                GroupMemberNameView(viewModel: viewModel, groupID: selection.groupID, member: item.member)
            }
            .sheet(item: $editingUser) { user in SavedUserNameView(viewModel: viewModel, user: user) }
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 360)
        #endif
    }
}

private struct ManagementMemberSelection: Identifiable {
    let member: GroupMember
    var id: String { member.id }
}
