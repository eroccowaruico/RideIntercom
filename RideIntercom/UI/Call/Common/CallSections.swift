import SwiftUI

struct CurrentCallSection: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    var excludesSelected = false
    var body: some View {
        if let id = viewModel.activeGroupID, viewModel.hasAnyActiveGroupConnection,
           !excludesSelected || viewModel.selectedGroup?.id != id,
           let group = viewModel.groups.first(where: { $0.id == id }) {
            Section("Current Call") {
                Button {
                    viewModel.selectGroup(group, connectIfIdle: false)
                    selectedTab = .call
                } label: { Label(viewModel.callTitle(for: group), systemImage: "phone.fill") }
                .accessibilityIdentifier("standardCurrentCallButton")
            }
        }
    }
}

struct CallErrorSection: View {
    let viewModel: IntercomViewModel
    var body: some View {
        if let message = viewModel.groupErrorMessage, message != viewModel.groupStorageNotice {
            Section {
                Label(LocalizedStringKey(message), systemImage: "exclamationmark.circle")
                    .accessibilityIdentifier("groupErrorLabel")
            }
        }
    }
}

struct CallStorageSection: View {
    let viewModel: IntercomViewModel
    var body: some View {
        if let message = viewModel.groupStorageNotice {
            GroupStorageSection(message: message, canReset: viewModel.groupStorageIssue == .corrupted,
                canReload: viewModel.activeGroupID == nil && viewModel.groupStorageIssue != .unsupportedVersion,
                reloadRequiresDisconnect: viewModel.activeGroupID != nil,
                reload: viewModel.reloadSavedGroups, reset: viewModel.resetSavedGroups)
        }
    }
}

struct DirectoryGroupLabel: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(group.name)
                if group.id == viewModel.activeGroupID && viewModel.hasAnyActiveGroupConnection {
                    Text(LocalizedStringKey(viewModel.callStatus(for: group.id).message))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            DestinationAvatar(isGroup: true)
        }
    }
}
