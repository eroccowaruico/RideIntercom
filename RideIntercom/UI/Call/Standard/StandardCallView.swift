import SwiftUI

struct StandardCallView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var addingUsers: IntercomGroup?
    @State private var editingMember: MemberNameSelection?

    var body: some View {
        List {
            if !viewModel.hasAnyActiveGroupConnection,
               let destination = viewModel.recentCallDestination, let title = viewModel.recentCallTitle {
                let access = viewModel.accountAccessID
                Section("Recent Call") {
                    Text(title).accessibilityIdentifier("recentCallName")
                    Button("Call Again", systemImage: "arrow.clockwise") {
                        viewModel.startCall(to: destination, accountAccessID: access)
                    }.accessibilityIdentifier("recentCallButton")
                }
            }
            CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab, excludesSelected: true)
            CallStorageSection(viewModel: viewModel)
            if let group = viewModel.selectedGroup {
                Section {
                    VStack(alignment: .leading, spacing: AppSpacing.l) {
                        Text(viewModel.callTitle(for: group))
                            .font(AppTypography.destinationTitle)
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: AppSpacing.m) {
                            if viewModel.standardCallStatus == .connecting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: statusSymbol)
                                    .foregroundStyle(statusColor)
                                    .accessibilityHidden(true)
                            }
                            Text(LocalizedStringKey(viewModel.standardCallStatus.message))
                                .accessibilityIdentifier("standardCallStatus")
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, AppSpacing.m)
                    connectionActions(group)
                    if viewModel.canShareSelectedGroup { CallInvitationButton(viewModel: viewModel, group: group) }
                    if group.kind == .direct {
                        Text("Share the invitation the first time. Your friend needs to open this call too; this does not send a notification.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if group.id == viewModel.activeGroupID {
                    audioControls
                    if viewModel.isAudioPausedForDeviceChange, viewModel.canResumeAudioOnThisDevice {
                        Section {
                            Text("Check your headphones or speaker, then resume audio.")
                            Button("Resume Audio") { viewModel.resumeAudioAfterDeviceChange() }
                                .buttonStyle(.glassProminent)
                                .controlSize(.large)
                                .disabled(viewModel.authenticatedPeerIDs.isEmpty)
                                .accessibilityIdentifier("resumeAudioButton")
                        }
                    }
                    if let notice = viewModel.audioRouteNotice { noticeSection(notice) }
                    if let notice = viewModel.connectivityNotice { noticeSection(notice) }
                    if let error = viewModel.audioErrorMessage { noticeSection(error) }
                }
                Section("People in This Call") {
                    ForEach(Array(group.members.dropFirst())) { member in
                        VStack(alignment: .leading, spacing: AppSpacing.m) {
                            HStack {
                                Text(member.resolvedDisplayName)
                                Spacer()
                                Button { editingMember = .init(groupID: group.id, member: member) } label: { Label("Edit Name", systemImage: "pencil") }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            if group.id == viewModel.activeGroupID, viewModel.authenticatedPeerIDs.contains(member.id) {
                                VStack(alignment: .leading) {
                                    Text("Volume")
                                        .accessibilityIdentifier("standardPeerVolumeLabel-\(member.id)")
                                    Slider(value: Binding(get: { Double(viewModel.remoteOutputVolume(for: member.id)) },
                                                          set: { viewModel.setRemoteOutputVolume(peerID: member.id, volume: Float($0)) }), in: 0...1) {
                                        Text("Volume for \(member.resolvedDisplayName)")
                                    }
                                }
                            }
                        }
                        .appDeleteActions(isEnabled: group.kind == .group) { viewModel.removeMember(member.id, from: group.id) }
                    }
                    if group.kind == .group {
                        Button("Add Saved Users", systemImage: "person.badge.plus") { addingUsers = group }
                            .disabled(!viewModel.canEditSavedGroups || viewModel.availableUsers(for: group.id).isEmpty
                                      || group.members.count >= IntercomGroup.maximumMemberCount)
                            .accessibilityIdentifier("addSavedUsersButton")
                    }
                }
            } else {
                Section {
                    ContentUnavailableView("Ready to Talk", systemImage: "phone", description: Text("Choose someone or a group to call."))
                    Button("Choose a User") { selectedTab = .users }
                    Button("Choose a Group") { selectedTab = .groups }
                }
            }
            CallErrorSection(viewModel: viewModel)
        }
        .scrollContentBackground(.hidden)
        .background(AppColorPalette.standardScreenBackground)
        .navigationTitle("Call")
        .accessibilityIdentifier("standardCallScreen")
        .sheet(item: $addingUsers) { group in SavedUsersView(viewModel: viewModel, groupID: group.id) }
        .sheet(item: $editingMember) { selection in
            GroupMemberNameView(viewModel: viewModel, groupID: selection.groupID, member: selection.member)
        }
    }

    private var statusSymbol: String {
        switch viewModel.standardCallStatus {
        case .chooseDestination, .ready: "phone"
        case .connecting: "hourglass"
        case .inCall: "waveform"
        case .audioPaused: "headphones"
        case .audioUnavailable: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch viewModel.standardCallStatus {
        case .inCall: AppColorPalette.success
        case .connecting, .audioPaused: AppColorPalette.warning
        case .audioUnavailable: AppColorPalette.danger
        case .chooseDestination, .ready: AppColorPalette.neutral
        }
    }

    @ViewBuilder private func connectionActions(_ group: IntercomGroup) -> some View {
        let reference = viewModel.currentCallReference
        let access = viewModel.accountAccessID
        if group.id == viewModel.activeGroupID, viewModel.hasAnyActiveGroupConnection {
            Button("End Call", systemImage: "phone.down.fill", role: .destructive) { viewModel.endCall(reference) }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityIdentifier("standardEndCallButton")
        } else {
            Button(LocalizedStringKey(viewModel.hasAnyActiveGroupConnection ? "Switch to This Call" : "Connect"), systemImage: "phone") {
                viewModel.startCall(to: .group(group.id), accountAccessID: access)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!viewModel.canStartCalls)
            .accessibilityIdentifier("standardConnectButton")
        }
    }

    private var audioControls: some View {
        let reference = viewModel.currentCallReference
        return Section("Audio") {
            if viewModel.canControlMicrophone {
                Toggle("Mute Microphone", isOn: Binding(get: { viewModel.isMuted }, set: { viewModel.setCallMuted($0, for: reference) }))
                    .accessibilityIdentifier("standardMuteToggle")
                Text(LocalizedStringKey(viewModel.isMuted ? "Microphone muted" : viewModel.isMicrophoneCaptureRunning ? "Microphone on" : "Microphone waiting for the call"))
                    .font(.footnote).accessibilityIdentifier("standardMicrophoneStatus")
            } else {
                Label("Control the microphone on your Watch", systemImage: "applewatch")
                    .accessibilityIdentifier("standardMicrophoneStatus")
            }
            Toggle("Mute Speaker", isOn: Binding(get: { viewModel.isOutputMuted }, set: { next in
                if viewModel.isOutputMuted != next { viewModel.toggleOutputMute() }
            }))
            VStack(alignment: .leading) {
                Text("Speaker Volume").accessibilityIdentifier("standardSpeakerVolumeLabel")
                Slider(value: Binding(get: { Double(viewModel.masterOutputVolume) }, set: { viewModel.setMasterOutputVolume(Float($0)) }), in: 0...2) {
                    Text("Speaker Volume")
                }
            }
            if viewModel.supportsSoundIsolation {
                Toggle("Voice Isolation", isOn: Binding(get: { viewModel.receiveMasterSoundIsolationEnabled },
                                                        set: viewModel.setReceiveMasterSoundIsolationEnabled))
            }
        }
    }

    private func noticeSection(_ message: String) -> some View {
        Section { Label(LocalizedStringKey(message), systemImage: "exclamationmark.circle") }
    }
}

private struct MemberNameSelection: Identifiable {
    let groupID: UUID
    let member: GroupMember
    var id: String { member.id }
}

