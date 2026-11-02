import SwiftUI

struct StandardCallView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var addingUsers: IntercomGroup?
    @State private var editingMember: MemberNameSelection?
    @State private var pendingEndReference: CallReference?
    @State private var confirmsEnd = false

    var body: some View {
        CallHeightLayout { compactHeight in
            if compactHeight, let group = viewModel.selectedGroup {
                HStack(alignment: .top, spacing: AppSpacing.screen) {
                    VStack(spacing: AppSpacing.m) {
                        hero(group, compact: true)
                        primaryActions(group, compact: true)
                    }
                    .frame(maxWidth: AppSize.callColumnMaxWidth)
                    List {
                        CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab, excludesSelected: true)
                        CallStorageSection(viewModel: viewModel)
                        detailSections(group)
                        CallErrorSection(viewModel: viewModel)
                    }
                    .accessibilityIdentifier("standardCallDetailsScroll")
                    .frame(maxWidth: AppSize.callColumnMaxWidth)
                }
                .padding(.horizontal, AppSpacing.screen)
            } else {
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
                            hero(group, compact: false)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            primaryActions(group, compact: false)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        detailSections(group)
                    } else {
                        Section {
                            ContentUnavailableView("Ready to Talk", systemImage: "phone", description: Text("Choose someone or a group to call."))
                            Button("Choose a User") { selectedTab = .users }
                            Button("Choose a Group") { selectedTab = .groups }
                        }
                    }
                    CallErrorSection(viewModel: viewModel)
                }
                .frame(maxWidth: AppSize.singleColumnMaxWidth)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColorPalette.standardScreenBackground)
        .navigationTitle("Call")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("standardCallScreen")
        .alert("End Call?", isPresented: $confirmsEnd) {
            Button("End Call", role: .destructive) {
                if let reference = pendingEndReference { viewModel.endCall(reference) }
                pendingEndReference = nil
            }.accessibilityIdentifier("standardConfirmEndCallButton")
            Button("Cancel", role: .cancel) { pendingEndReference = nil }
                .accessibilityIdentifier("standardCancelEndCallButton")
        }
        .sheet(item: $addingUsers) { group in SavedUsersView(viewModel: viewModel, groupID: group.id) }
        .sheet(item: $editingMember) { selection in
            GroupMemberNameView(viewModel: viewModel, groupID: selection.groupID, member: selection.member)
        }
    }

    private func hero(_ group: IntercomGroup, compact: Bool) -> some View {
        VStack(spacing: compact ? AppSpacing.xs : AppSpacing.l) {
            DestinationAvatar(isGroup: group.kind == .group, diameter: compact ? 44 : 64)
            Text(viewModel.callTitle(for: group))
                .font(compact ? .headline : AppTypography.destinationTitle)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: AppSpacing.m) {
                if viewModel.standardCallStatus == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusSymbol).foregroundStyle(statusColor).accessibilityHidden(true)
                }
                Text(LocalizedStringKey(viewModel.standardCallStatus.message))
                    .accessibilityIdentifier("standardCallStatus")
            }.font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 0 : AppSpacing.m)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("standardCallHero")
    }

    @ViewBuilder private func detailSections(_ group: IntercomGroup) -> some View {
        if viewModel.canShareSelectedGroup { Section { CallInvitationButton(viewModel: viewModel, group: group) } }
        if group.kind == .direct {
            Section { Text("Share the invitation the first time. Your friend needs to open this call too; this does not send a notification.")
                .font(.footnote).foregroundStyle(.secondary) }
        }
        if group.id == viewModel.activeGroupID {
            audioDetails
            if viewModel.isAudioPausedForDeviceChange, viewModel.canResumeAudioOnThisDevice {
                Section {
                    Text("Check your headphones or speaker, then resume audio.")
                    Button("Resume Audio") { viewModel.resumeAudioAfterDeviceChange() }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .disabled(viewModel.authenticatedPeerIDs.isEmpty)
                        .accessibilityIdentifier("resumeAudioButton")
                }
            }
            if let notice = viewModel.audioRouteNotice { noticeSection(notice) }
            if let notice = viewModel.connectivityNotice { noticeSection(notice) }
            if let error = viewModel.audioErrorMessage { noticeSection(error) }
        }
        Section {
            ForEach(Array(group.members.dropFirst())) { member in
                VStack(alignment: .leading, spacing: AppSpacing.m) {
                    HStack {
                        DestinationAvatar(isGroup: false)
                        Text(member.resolvedDisplayName)
                        Spacer()
                        Button { editingMember = .init(groupID: group.id, member: member) } label: { Label("Edit Name", systemImage: "pencil") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                    }
                    if group.id == viewModel.activeGroupID, viewModel.authenticatedPeerIDs.contains(member.id) {
                        VStack(alignment: .leading) {
                            Text("Volume").accessibilityIdentifier("standardPeerVolumeLabel-\(member.id)")
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
        } header: {
            Text("People in This Call").accessibilityIdentifier("standardCallParticipantsHeading")
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

    @ViewBuilder private func primaryActions(_ group: IntercomGroup, compact: Bool) -> some View {
        let reference = viewModel.currentCallReference
        let access = viewModel.accountAccessID
        if group.id == viewModel.activeGroupID, viewModel.hasAnyActiveGroupConnection {
            let diameter = compact ? AppSize.callControlCompactDiameter : AppSize.callControlDiameter
            GlassEffectContainer(spacing: AppSpacing.callControls) {
                ViewThatFits(in: .horizontal) {
                    controlRow(reference: reference, diameter: diameter, vertical: false)
                    controlRow(reference: reference, diameter: diameter, vertical: true)
                }
            }
            if viewModel.canControlMicrophone {
                Text(LocalizedStringKey(viewModel.isMuted ? "Microphone muted" : viewModel.isMicrophoneCaptureRunning ? "Microphone on" : "Microphone waiting for the call"))
                    .font(.footnote).accessibilityIdentifier("standardMicrophoneStatus")
            }
        } else {
            Button(LocalizedStringKey(viewModel.hasAnyActiveGroupConnection ? "Switch to This Call" : "Connect"), systemImage: "phone") {
                viewModel.startCall(to: .group(group.id), accountAccessID: access)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .disabled(!viewModel.canStartCalls)
            .accessibilityIdentifier("standardConnectButton")
        }
    }

    private func controlRow(reference: CallReference, diameter: CGFloat, vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: AppSpacing.m)) : AnyLayout(HStackLayout(alignment: .top, spacing: AppSpacing.callControls))
        return layout {
            if viewModel.canControlMicrophone {
                VStack {
                    Button { viewModel.setCallMuted(!viewModel.isMuted, for: reference) } label: {
                        Image(systemName: "mic.slash").frame(width: diameter, height: diameter)
                    }
                    .modifier(CallMuteButtonStyle(isMuted: viewModel.isMuted))
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Mute Microphone")
                    .accessibilityValue(viewModel.isMuted ? "Muted" : "Unmuted")
                    .accessibilityAddTraits(viewModel.isMuted ? .isSelected : [])
                    .accessibilityIdentifier("standardMuteButton")
                    Text(viewModel.isMuted ? "Muted" : "Mute").font(.caption)
                }
            } else {
                Label("Control the microphone on your Watch", systemImage: "applewatch")
                    .font(.caption).accessibilityIdentifier("standardMicrophoneStatus")
            }
            VStack {
                Button { viewModel.toggleOutputMute() } label: {
                    Image(systemName: "speaker.slash").frame(width: diameter, height: diameter)
                }
                .modifier(CallMuteButtonStyle(isMuted: viewModel.isOutputMuted))
                .buttonBorderShape(.circle)
                .accessibilityLabel("Mute Speaker")
                .accessibilityValue(viewModel.isOutputMuted ? "Muted" : "Unmuted")
                .accessibilityAddTraits(viewModel.isOutputMuted ? .isSelected : [])
                .accessibilityIdentifier("standardSpeakerButton")
                Text("Speaker").font(.caption)
            }
            VStack {
                Button(role: .destructive) { pendingEndReference = reference; confirmsEnd = true } label: {
                    Image(systemName: "phone.down.fill").frame(width: diameter, height: diameter)
                }
                .buttonStyle(.glassProminent).tint(AppColorPalette.danger)
                .buttonBorderShape(.circle)
                .accessibilityLabel("End Call")
                .accessibilityIdentifier("standardEndCallButton")
                Text("End Call").font(.caption)
            }.padding(.leading, vertical ? 0 : max(0, AppSpacing.destructiveSeparation - AppSpacing.callControls))
        }
    }

    private var audioDetails: some View {
        Section("Audio") {
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


private struct CallMuteButtonStyle: ViewModifier {
    let isMuted: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isMuted {
            content.buttonStyle(.glassProminent).tint(AppColorPalette.danger)
        } else {
            content.buttonStyle(.glass)
        }
    }
}
