import SwiftUI

/// The call opens over the lists: a sheet on iPhone, a trailing column on iPad and Mac.
struct CallPanel: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    let close: () -> Void
    @State private var settings: DestinationSettingsTarget?
    @State private var addingMembers: IntercomGroup?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.interfaceMode == .standard {
                    StandardCallView(viewModel: viewModel, selectedTab: $selectedTab)
                } else {
                    CallEntryView(viewModel: viewModel, selectedTab: $selectedTab)
                }
            }
            #if os(iOS)
            // A sheet's title stays inline so the state and controls keep the height.
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "chevron.down", action: close)
                        .accessibilityIdentifier("closeCallButton")
                }
                // Always present, so the toolbar does not change shape between calls.
                ToolbarItem(placement: .primaryAction) {
                    CallMoreMenu(viewModel: viewModel, settings: $settings, addingMembers: $addingMembers)
                }
            }
        }
        .destinationSettingsSheet($settings, viewModel: viewModel)
        .sheet(item: $addingMembers) { group in SavedUsersView(viewModel: viewModel, groupID: group.id) }
        .inspectorColumnWidth(min: 320, ideal: 380, max: 420)
    }
}

/// The call's More menu: settings for this group or person, adding members, and the invitation.
struct CallMoreMenu: View {
    let viewModel: IntercomViewModel
    @Binding var settings: DestinationSettingsTarget?
    @Binding var addingMembers: IntercomGroup?

    var body: some View {
        if let group = viewModel.selectedGroup {
            Menu {
                if group.kind == .group {
                    Button("Group Settings", systemImage: "gearshape") { settings = .group(group.id) }
                        .accessibilityIdentifier("callGroupSettingsButton")
                    Button(LocalizedStringKey(viewModel.interfaceMode == .standard ? "Add Members" : "Add Saved Users"),
                           systemImage: "person.badge.plus") { addingMembers = group }
                        .disabled(!viewModel.canEditSavedGroups || viewModel.availableUsers(for: group.id).isEmpty
                                  || group.members.count >= IntercomGroup.maximumMemberCount)
                        .accessibilityIdentifier("callAddMembersButton")
                } else {
                    // A removed saved user leaves the entry disabled, so the menu is never empty.
                    let userID = viewModel.savedUserID(forDirectCall: group)
                    Button("User Settings", systemImage: "gearshape") { settings = userID.map { .user($0) } }
                        .disabled(userID == nil)
                        .accessibilityIdentifier("callUserSettingsButton")
                }
                if viewModel.canShareSelectedGroup {
                    CallInvitationButton(viewModel: viewModel, group: group)
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("callMoreMenu")
        }
    }
}

/// While the call is closed: name, state and mute, with End in the long-press menu.
struct CallAccessory: View {
    let viewModel: IntercomViewModel
    let open: () -> Void

    var body: some View {
        if let id = viewModel.activeGroupID, let group = viewModel.groups.first(where: { $0.id == id }) {
            let reference = viewModel.currentCallReference
            HStack(spacing: AppSpacing.m) {
                Button(action: open) {
                    Label {
                        Text(viewModel.callTitle(for: group)).lineLimit(1)
                    } icon: {
                        CallStatusSymbol(status: viewModel.callStatus(for: id))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the call")
                .accessibilityIdentifier("callAccessoryOpenButton")
                if viewModel.canControlMicrophone {
                    Button { viewModel.setCallMuted(!viewModel.isMuted, for: reference) } label: {
                        Image(systemName: "mic.slash")
                            .foregroundStyle(viewModel.isMuted ? AppColorPalette.danger : Color.primary)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mute")
                    .accessibilityValue(viewModel.isMuted ? "Muted" : "Unmuted")
                    .accessibilityAddTraits(viewModel.isMuted ? .isSelected : [])
                    .accessibilityIdentifier("callAccessoryMuteButton")
                }
            }
            .padding(.horizontal, AppSpacing.l)
            .contextMenu {
                Button("End Call", systemImage: "phone.down.fill", role: .destructive) { viewModel.endCall(reference) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("callAccessory")
        }
    }
}

/// The last destination leads the people list so talking again is one tap.
struct RecentCallSection: View {
    let viewModel: IntercomViewModel
    @Binding var pendingSwitch: CallDestination?
    let onOpen: () -> Void

    var body: some View {
        if !viewModel.hasAnyActiveGroupConnection,
           let destination = viewModel.recentCallDestination, let title = viewModel.recentCallTitle {
            Section("Recent Call") {
                Button { viewModel.open(destination, pending: $pendingSwitch, onOpen: onOpen) } label: {
                    Label { Text(title).accessibilityIdentifier("recentCallName") } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .accessibilityIdentifier("recentCallButton")
            }
        }
    }
}

/// In-app status symbol: the system surfaces' symbols and colors without their widget-only
/// modifiers, and a real progress view while connecting. Widget rendering stays in
/// `CallSurfaceStatusIcon`.
struct CallStatusSymbol: View {
    let status: StandardCallStatus

    var body: some View {
        if status == .connecting {
            ProgressView().controlSize(.mini).tint(AppColorPalette.warning)
        } else {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch status {
        case .chooseDestination, .ready, .connecting: "phone"
        case .inCall: "waveform"
        case .audioPaused: "headphones"
        case .audioUnavailable: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .chooseDestination, .ready, .connecting: AppColorPalette.neutral
        case .inCall: AppColorPalette.success
        case .audioPaused: AppColorPalette.warning
        case .audioUnavailable: AppColorPalette.danger
        }
    }
}
