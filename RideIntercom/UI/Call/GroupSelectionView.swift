import SwiftUI
import RTC

struct GroupSelectionView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        List {
            if let message = viewModel.groupStorageNotice {
                GroupStorageSection(message: message,
                    canReset: viewModel.groupStorageIssue == .corrupted,
                    canReload: viewModel.activeGroupID == nil && viewModel.groupStorageIssue != .unsupportedVersion,
                    reloadRequiresDisconnect: viewModel.activeGroupID != nil,
                    reload: viewModel.reloadSavedGroups, reset: viewModel.resetSavedGroups)
            }
            Section("Recent Groups") {
                if viewModel.groups.isEmpty {
                    Text("Create a group to start a call.")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(AppColorPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appCallCardStyle()
                        .listRowInsets(EdgeInsets(top: AppSpacing.m, leading: AppSpacing.screen, bottom: AppSpacing.m, trailing: AppSpacing.screen))
                        .listRowBackground(Color.clear)
                }

                ForEach(viewModel.groups) { group in
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
                Button {
                    viewModel.createTalkGroup()
                } label: {
                    Label("Create Talk Group", systemImage: "plus")
                }
                .accessibilityIdentifier("createGroupButton")
                .disabled(!viewModel.canEditSavedGroups)
            }
        }
        .accessibilityIdentifier("groupSelectionList")
    }

    private func groupRowIconColor(for group: IntercomGroup) -> Color {
        viewModel.activeGroupID == group.id ? AppColorPalette.success : AppColorPalette.textSecondary
    }
}
