import SwiftUI

/// Group Settings and User Settings open from named entries: the call's More menu and
/// a list row's context menu or swipe. A row tap only connects.
enum DestinationSettingsTarget: Identifiable, Hashable {
    case group(UUID)
    case user(UUID)
    var id: Self { self }
}

extension View {
    /// Long-press and swipe offer the settings entry first, then Delete, which always asks first:
    /// Delete only fills `pending`; the list shows the alert (`destinationDeleteConfirmation`).
    func destinationRowActions(_ settingsTitle: LocalizedStringKey, settings: @escaping () -> Void,
                               canDelete: Bool = true, pending: Binding<PendingDestinationDelete?>,
                               name: String, endsCall: Bool = false,
                               delete: @escaping () -> Void) -> some View {
        let ask = { pending.wrappedValue = PendingDestinationDelete(name: name, endsCall: endsCall, perform: delete) }
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
            Button(action: settings) { Label(settingsTitle, systemImage: "gearshape") }
        }
        .contextMenu {
            Button(action: settings) { Label(settingsTitle, systemImage: "gearshape") }
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
        }
    }

    /// The delete confirmation for a list's rows. `endsCall` says the live connection will be cut.
    func destinationDeleteConfirmation(_ pending: Binding<PendingDestinationDelete?>) -> some View {
        alert(pending.wrappedValue.map { Text("Delete \($0.name)?") } ?? Text(verbatim: ""), isPresented: Binding(
            get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
              presenting: pending.wrappedValue) { item in
            Button(LocalizedStringKey(item.endsCall ? "Disconnect and Delete" : "Delete"), role: .destructive, action: item.perform)
                .accessibilityIdentifier("confirmDeleteDestinationButton")
            Button("Cancel", role: .cancel) { }
        } message: { item in
            if item.endsCall { Text("The current connection ends.") }
        }
    }

    func destinationSettingsSheet(_ target: Binding<DestinationSettingsTarget?>, viewModel: IntercomViewModel) -> some View {
        sheet(item: target) { target in
            switch target {
            case .group(let id): GroupSettingsView(viewModel: viewModel, groupID: id)
            case .user(let id):
                if let user = viewModel.savedRemoteUsers.first(where: { $0.id == id }) {
                    UserSettingsView(viewModel: viewModel, user: user)
                }
            }
        }
    }
}

/// Name, members, invitation and Delete Group for one saved group.
struct GroupSettingsView: View {
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
                                .memberRowActions(edit: { editingMember = member }, pending: $pendingRemoval,
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

extension View {
    /// Member names are changed from the row's menu or swipe, not a pencil button.
    func memberRowActions(edit: @escaping () -> Void, canRemove: Bool = true,
                          pending: Binding<PendingMemberRemoval?>, name: String,
                          remove: @escaping () -> Void) -> some View {
        let ask = { pending.wrappedValue = PendingMemberRemoval(name: name, perform: remove) }
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
            Button(action: edit) { Label("Edit Name", systemImage: "pencil") }
        }
        .contextMenu {
            Button(action: edit) { Label("Edit Name", systemImage: "pencil") }
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
        }
    }

    /// Removing a member always asks first. Held by the screen: an alert on a row does not
    /// appear once its swipe closes.
    func memberRemoveConfirmation(_ pending: Binding<PendingMemberRemoval?>) -> some View {
        alert(pending.wrappedValue.map { Text("Remove \($0.name) from the group?") } ?? Text(verbatim: ""),
              isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
              presenting: pending.wrappedValue) { item in
            Button("Remove", role: .destructive, action: item.perform)
                .accessibilityIdentifier("confirmRemoveMemberButton")
            Button("Cancel", role: .cancel) { }
        }
    }
}

struct PendingDestinationDelete {
    let name: String
    let endsCall: Bool
    let perform: () -> Void
}

struct PendingMemberRemoval {
    let name: String
    let perform: () -> Void
}
