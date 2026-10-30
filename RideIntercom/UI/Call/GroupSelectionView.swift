import SwiftUI
import RTC

struct GroupSelectionView: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var showingUsers = false

    var body: some View {
        List {
            if let message = viewModel.groupStorageNotice {
                GroupStorageSection(message: message,
                    canReset: viewModel.groupStorageIssue == .corrupted,
                    canReload: viewModel.activeGroupID == nil && viewModel.groupStorageIssue != .unsupportedVersion,
                    reloadRequiresDisconnect: viewModel.activeGroupID != nil,
                    reload: viewModel.reloadSavedGroups, reset: viewModel.resetSavedGroups)
            }
            if let active = viewModel.activeDirectCall {
                Section("Current Call") {
                    Button { viewModel.selectGroup(active) } label: {
                        Label(viewModel.callTitle(for: active), systemImage: "phone.fill")
                    }
                    .accessibilityIdentifier("activeDirectCallButton")
                }
            }
            if !viewModel.savedRemoteUsers.isEmpty {
                Section {
                    ForEach(viewModel.savedRemoteUsers) { user in
                        Button { viewModel.selectUser(user.id) } label: {
                            Label(user.displayName, systemImage: "person.crop.circle")
                                .frame(minHeight: 44)
                        }
                        .accessibilityHint("Opens your individual call with this user.")
                        .accessibilityIdentifier("userCall-\(user.id)")
                    }
                } header: { Text("Users") } footer: {
                    Text("Only people you invited directly, or whose invitations you accepted, appear here.")
                }
            }
            Section("Recent Groups") {
                if viewModel.regularGroups.isEmpty {
                    Text("Create a group to start a call.")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(AppColorPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appCallCardStyle()
                        .listRowInsets(EdgeInsets(top: AppSpacing.m, leading: AppSpacing.screen, bottom: AppSpacing.m, trailing: AppSpacing.screen))
                        .listRowBackground(Color.clear)
                }

                ForEach(viewModel.regularGroups) { group in
                    Button {
                        viewModel.selectGroup(group)
                    } label: {
                        GroupRowView(
                            title: group.name,
                            subtitle: "\(group.members.count) members",
                            iconColor: groupRowIconColor(for: group)
                        )
                    }
                    .buttonStyle(.plain)
                    .appListCardRowStyle()
                    .accessibilityLabel(group.name)
                    .accessibilityValue("\(group.members.count) members")
                    .accessibilityHint("Opens the call screen for this group.")
                    .accessibilityIdentifier("groupRow-\(group.name)")
                    .appDeleteActions {
                        viewModel.deleteGroup(group.id)
                    }
                }
            }
        }
        .listStyle(.automatic)
        .scrollContentBackground(.hidden)
        .background(AppColorPalette.callScreenBackground)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingUsers = true } label: { Label("Saved Users", systemImage: "person.2") }
                    .accessibilityIdentifier("savedUsersButton")
                    .disabled(!viewModel.canEditSavedGroups)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.createTalkGroup()
                } label: {
                    Label("Create Talk Group", systemImage: "plus")
                }
                .accessibilityIdentifier("createGroupButton")
                .disabled(!viewModel.canEditSavedGroups)
            }
        }
        .sheet(isPresented: $showingUsers) { SavedUsersView(viewModel: viewModel) }
        .accessibilityIdentifier("groupSelectionList")
    }

    private func groupRowIconColor(for group: IntercomGroup) -> Color {
        viewModel.activeGroupID == group.id ? AppColorPalette.success : AppColorPalette.textSecondary
    }
}
