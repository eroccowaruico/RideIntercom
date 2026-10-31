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
            StandardStorageSection(viewModel: viewModel)
            if let group = viewModel.selectedGroup {
                Section {
                    Text(viewModel.callTitle(for: group)).font(.title2).accessibilityAddTraits(.isHeader)
                    Text(LocalizedStringKey(viewModel.standardCallStatus.message))
                        .accessibilityIdentifier("standardCallStatus")
                    connectionActions(group)
                    if viewModel.canShareSelectedGroup { CallInvitationButton(viewModel: viewModel, group: group) }
                    if group.kind == .direct {
                        Text("Share the invitation the first time. Your friend needs to open this call too; this does not send a notification.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if group.id == viewModel.activeGroupID {
                    audioControls
                    if viewModel.isAudioPausedForDeviceChange {
                        Section {
                            Text("Check your headphones or speaker, then resume audio.")
                            Button("Resume Audio") { viewModel.resumeAudioAfterDeviceChange() }
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
                        VStack(alignment: .leading, spacing: 8) {
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
            StandardErrorSection(viewModel: viewModel)
        }
        .navigationTitle("Call")
        .accessibilityIdentifier("standardCallScreen")
        .sheet(item: $addingUsers) { group in SavedUsersView(viewModel: viewModel, groupID: group.id) }
        .sheet(item: $editingMember) { selection in
            GroupMemberNameView(viewModel: viewModel, groupID: selection.groupID, member: selection.member)
        }
    }

    @ViewBuilder private func connectionActions(_ group: IntercomGroup) -> some View {
        let reference = viewModel.currentCallReference
        let access = viewModel.accountAccessID
        if group.id == viewModel.activeGroupID, viewModel.hasAnyActiveGroupConnection {
            Button("End Call", role: .destructive) { viewModel.endCall(reference) }
                .accessibilityIdentifier("standardEndCallButton")
        } else {
            Button(LocalizedStringKey(viewModel.hasAnyActiveGroupConnection ? "Switch to This Call" : "Connect"), systemImage: "phone") {
                viewModel.startCall(to: .group(group.id), accountAccessID: access)
            }
            .disabled(!viewModel.canStartCalls)
            .accessibilityIdentifier("standardConnectButton")
        }
    }

    private var audioControls: some View {
        let reference = viewModel.currentCallReference
        return Section("Audio") {
            Toggle("Mute Microphone", isOn: Binding(get: { viewModel.isMuted }, set: { viewModel.setCallMuted($0, for: reference) }))
                .accessibilityIdentifier("standardMuteToggle")
            Text(LocalizedStringKey(viewModel.isMuted ? "Microphone muted" : viewModel.isMicrophoneCaptureRunning ? "Microphone on" : "Microphone waiting for the call"))
                .font(.footnote).accessibilityIdentifier("standardMicrophoneStatus")
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

struct StandardErrorSection: View {
    let viewModel: IntercomViewModel
    var body: some View {
        if let message = viewModel.groupErrorMessage, message != viewModel.groupStorageNotice {
            Section { Label(LocalizedStringKey(message), systemImage: "exclamationmark.circle") }
        }
    }
}

struct StandardStorageSection: View {
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
