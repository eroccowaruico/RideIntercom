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

/// While the call is closed: the state symbol, the name over the state word, Mute and End.
/// Only End here asks first, since the bar can be touched without opening the call.
struct CallAccessory: View {
    let viewModel: IntercomViewModel
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pendingEnd: CallReference?

    var body: some View {
        if let id = viewModel.activeGroupID, let group = viewModel.groups.first(where: { $0.id == id }) {
            let reference = viewModel.currentCallReference
            let name = viewModel.callTitle(for: group)
            let state = stateWord(viewModel.callStatus(for: id))
            HStack(spacing: AppSpacing.m) {
                Button(action: open) {
                    HStack(spacing: AppSpacing.m) {
                        CallStatusSymbol(status: viewModel.callStatus(for: id))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            // At accessibility sizes the name stays on one line and the state word gives way.
                            if !dynamicTypeSize.isAccessibilitySize {
                                Text(verbatim: state).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(name), \(state)"))
                .accessibilityHint("Opens the call")
                .accessibilityIdentifier("callAccessoryOpenButton")
                if viewModel.canControlMicrophone {
                    Button { viewModel.setCallMuted(!viewModel.isMuted, for: reference) } label: {
                        circle("mic.slash", foreground: viewModel.isMuted ? .white : .primary,
                               fill: viewModel.isMuted ? AppColorPalette.danger : Color.secondary.opacity(0.16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mute")
                    .accessibilityValue(viewModel.isMuted ? "Muted" : "Unmuted")
                    .accessibilityAddTraits(viewModel.isMuted ? .isSelected : [])
                    .accessibilityIdentifier("callAccessoryMuteButton")
                }
                // End keeps a glass circle with a red symbol, never a red fill beside a muted one.
                Button { pendingEnd = reference } label: {
                    circle("phone.down.fill", foreground: AppColorPalette.danger, fill: Color.secondary.opacity(0.16))
                }
                .buttonStyle(.plain)
                .padding(.leading, AppSpacing.xs)
                .accessibilityLabel("End Call")
                .accessibilityIdentifier("callAccessoryEndButton")
            }
            .padding(.leading, AppSpacing.l)
            .padding(.trailing, AppSpacing.xs)
            .contextMenu {
                Button("Open Call", systemImage: "phone.fill", action: open)
                if viewModel.canControlMicrophone {
                    Button("Mute", systemImage: "mic.slash") { viewModel.setCallMuted(!viewModel.isMuted, for: reference) }
                }
                Button("End Call", systemImage: "phone.down.fill", role: .destructive) { pendingEnd = reference }
            }
            .confirmationDialog(Text("Disconnect from \(name)?"), isPresented: Binding(
                get: { pendingEnd != nil }, set: { if !$0 { pendingEnd = nil } }),
                                titleVisibility: .visible, presenting: pendingEnd) { shown in
                // Ends only the call that was shown; a call that changed meanwhile is not ended.
                Button("End", role: .destructive) { viewModel.endCall(shown) }
                    .accessibilityIdentifier("callAccessoryConfirmEndButton")
                Button("Cancel", role: .cancel) { }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("callAccessory")
        }
    }

    /// The state word; while muted it adds Muted ("In a call · Muted").
    private func stateWord(_ status: StandardCallStatus) -> String {
        let word = String(localized: .init(stringLiteral: status.title))
        return viewModel.isMuted && viewModel.canControlMicrophone ? String(localized: "\(word) · Muted") : word
    }

    private func circle(_ symbol: String, foreground: Color, fill: Color) -> some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(foreground)
            .frame(width: 34, height: 34)
            .background(fill, in: Circle())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
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
