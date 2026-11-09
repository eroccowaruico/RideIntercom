import SwiftUI

struct AdvancedUsersView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var settings: DestinationSettingsTarget?
    @State private var pendingDelete: PendingDestinationDelete?
    @State private var pendingSwitch: CallDestination?

    var body: some View {
        List {
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
            CallStorageSection(viewModel: viewModel)
            Section {
                if viewModel.savedRemoteUsers.isEmpty {
                    ContentUnavailableView("No Saved Users", systemImage: "person.2",
                        description: Text("Invite someone, or accept an invitation to save each other."))
                }
                ForEach(viewModel.savedRemoteUsers) { user in
                    Button {
                        viewModel.open(.user(user.id), pending: $pendingSwitch) { selectedTab = .call }
                    } label: {
                        AdvancedRecordRow(title: user.resolvedDisplayName, value: userValue(user),
                                          detail: "Name shared by this person: \(user.displayName)",
                                          state: viewModel.isInCall(with: .user(user.id))
                                              ? viewModel.callStatus(for: viewModel.activeGroupID).title : nil)
                    }
                    .directoryRowButtonStyle()
                    .accessibilityIdentifier("standardUser-\(user.id)")
                    .destinationRowActions("User Settings", settings: { settings = .user(user.id) },
                                           pending: $pendingDelete, name: user.resolvedDisplayName) {
                        _ = viewModel.removeSavedUser(user.id)
                    }
                }
            } header: {
                Text(verbatim: "Saved Users \(viewModel.savedRemoteUsers.count)")
            } footer: {
                Text("Only direct invitations save a person here. Removing a saved user keeps your existing groups and calls.")
            }
            AdvancedInvitationsSection(viewModel: viewModel)
            CallErrorSection(viewModel: viewModel)
        }
        .readableScrollWidth()
        .navigationTitle("Users")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Invite Someone", systemImage: "plus") { viewModel.beginContactInvitationPresentation() }
                    .disabled(!viewModel.canEditSavedGroups)
                    .accessibilityIdentifier("inviteContactButton")
            }
        }
        .accessibilityIdentifier("standardUsersList")
        .destinationSettingsSheet($settings, viewModel: viewModel)
        .destinationDeleteConfirmation($pendingDelete)
        .switchCallConfirmation($pendingSwitch, viewModel: viewModel) { selectedTab = .call }
    }

    /// `SavedUser` as stored: the direct group's short id and the device count, or no direct group yet.
    private func userValue(_ user: SavedUser) -> String {
        let devices = user.deviceKeys?.count ?? user.memberIDs.count
        guard let direct = viewModel.existingDirectCall(for: user.id) else { return "No direct group yet" }
        return "Direct \(direct.id.shortRecordID) · \(devices) \(devices == 1 ? "device" : "devices")"
    }
}

struct AdvancedGroupsView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var createsGroup = false
    @State private var previousSelection: UUID?
    @State private var settings: DestinationSettingsTarget?
    @State private var pendingDelete: PendingDestinationDelete?
    @State private var pendingSwitch: CallDestination?

    var body: some View {
        List {
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
            CallStorageSection(viewModel: viewModel)
            Section {
                if viewModel.regularGroups.isEmpty {
                    ContentUnavailableView("No Groups Yet", systemImage: "person.3", description: Text("Create a group or open an invitation from a friend."))
                }
                ForEach(viewModel.regularGroups) { group in
                    Button {
                        viewModel.open(.group(group.id), pending: $pendingSwitch) { selectedTab = .call }
                    } label: {
                        AdvancedRecordRow(title: group.name, value: groupValue(group), detail: group.id.shortRecordID,
                                          monospacedDetail: true,
                                          state: viewModel.isInCall(with: .group(group.id)) ? "active" : nil)
                    }
                    .directoryRowButtonStyle()
                    .accessibilityIdentifier("standardGroup-\(group.id)")
                    .destinationRowActions("Group Settings", settings: { settings = .group(group.id) },
                                           pending: $pendingDelete, name: group.name, endsCall: viewModel.isInCall(with: .group(group.id))) {
                        viewModel.deleteGroup(group.id)
                    }
                }
            } header: {
                Text(verbatim: "Saved Groups \(viewModel.regularGroups.count)")
            }
            let directGroups = viewModel.groups.filter { $0.kind == .direct }
            if !directGroups.isEmpty {
                // The internal groups behind one-to-one calls; members are fixed, so no row actions.
                Section {
                    ForEach(directGroups) { group in
                        let row = AdvancedRecordRow(title: viewModel.callTitle(for: group),
                                                    value: "Direct · \(group.members.count.memberCountText)",
                                                    detail: group.id.shortRecordID, monospacedDetail: true,
                                                    state: viewModel.isInCall(with: .group(group.id)) ? "active" : nil)
                        if let userID = viewModel.savedUserID(forDirectCall: group) {
                            Button {
                                viewModel.open(.user(userID), pending: $pendingSwitch) { selectedTab = .call }
                            } label: { row }
                            .directoryRowButtonStyle()
                            .accessibilityIdentifier("advancedDirectGroup-\(group.id)")
                        } else {
                            row.accessibilityIdentifier("advancedDirectGroup-\(group.id)")
                        }
                    }
                } header: {
                    Text(verbatim: "Direct Groups \(directGroups.count)")
                }
            }
            CallErrorSection(viewModel: viewModel)
        }
        .readableScrollWidth()
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
        .destinationSettingsSheet($settings, viewModel: viewModel)
        .destinationDeleteConfirmation($pendingDelete)
        .switchCallConfirmation($pendingSwitch, viewModel: viewModel) { selectedTab = .call }
        .accessibilityIdentifier("standardGroupsList")
    }

    /// Member count and whether the stored call key is present (`groupsMissingKeys`).
    private func groupValue(_ group: IntercomGroup) -> String {
        "\(group.members.count.memberCountText) · \(viewModel.groupsMissingKeys.contains(group.id) ? "key missing" : "key ready")"
    }
}

/// One implementation record: the name, its stored values, an identifier line and the live state.
/// Advanced rows never reuse Standard's list parts or wording.
private struct AdvancedRecordRow: View {
    let title: String
    let value: String
    let detail: String
    var monospacedDetail = false
    var state: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.headline).foregroundStyle(Color.primary)
                Text(verbatim: value).font(.subheadline).foregroundStyle(Color.primary)
                Text(verbatim: detail)
                    .font(monospacedDetail ? .caption.monospaced() : .caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: AppSpacing.s)
            if let state {
                Label {
                    Text(verbatim: state)
                } icon: {
                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(AppColorPalette.success)
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private extension Int {
    var memberCountText: String { "\(self) \(self == 1 ? "member" : "members")" }
}

private extension UUID {
    /// The first eight hex digits, as the design shows record ids.
    var shortRecordID: String { String(uuidString.prefix(8)).lowercased() }
}
