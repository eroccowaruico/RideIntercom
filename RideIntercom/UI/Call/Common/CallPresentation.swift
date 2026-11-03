import SwiftUI

/// The call opens over the lists: a sheet on iPhone, a trailing column on iPad and Mac.
struct CallPanel: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.interfaceMode == .standard {
                    StandardCallView(viewModel: viewModel, selectedTab: $selectedTab)
                } else {
                    CallEntryView(viewModel: viewModel, selectedTab: $selectedTab)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "chevron.down", action: close)
                        .accessibilityIdentifier("closeCallButton")
                }
            }
        }
        .inspectorColumnWidth(min: 320, ideal: 380, max: 420)
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
                        CallSurfaceStatusIcon(status: viewModel.callStatus(for: id))
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
