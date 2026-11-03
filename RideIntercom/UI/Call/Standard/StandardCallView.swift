import SwiftUI

struct StandardCallView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var addingUsers: IntercomGroup?
    @State private var editingMember: MemberNameSelection?
    @State private var pendingEndReference: CallReference?
    @State private var confirmsEnd = false

    var body: some View {
        CallHeightLayout { compactHeight, regularWidth in
            if compactHeight, dynamicTypeSize.isAccessibilitySize, let group = viewModel.selectedGroup {
                VStack(spacing: 0) {
                    List {
                        Section {
                            accessibleCompactHero(group)
                            if viewModel.canControlMicrophone { microphoneStatus }
                        }
                        CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab, excludesSelected: true)
                        CallStorageSection(viewModel: viewModel)
                        detailSections(group)
                        CallErrorSection(viewModel: viewModel)
                    }
                    .frame(maxHeight: .infinity)
                    .clipped()
                    .accessibilityIdentifier("standardCallDetailsScroll")
                    VStack {
                        primaryActions(group, compact: true, showsStatus: false)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppSpacing.screen)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("standardCallFixedControls")
                }
            } else if (compactHeight || regularWidth), let group = viewModel.selectedGroup {
                HStack(alignment: .top, spacing: AppSpacing.screen) {
                    VStack(spacing: AppSpacing.m) {
                        hero(group, compact: compactHeight)
                        primaryActions(group, compact: compactHeight)
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
                    }
                    CallErrorSection(viewModel: viewModel)
                }
                .frame(maxWidth: AppSize.singleColumnMaxWidth)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColorPalette.standardScreenBackground)
        .sensoryFeedback(.selection, trigger: viewModel.isMuted)
        .sensoryFeedback(.selection, trigger: viewModel.isOutputMuted)
        .sensoryFeedback(trigger: viewModel.hasAnyActiveGroupConnection) { old, new in
            old && !new ? .stop : nil
        }
        .sensoryFeedback(trigger: viewModel.callStatus(for: viewModel.activeGroupID)) { old, new in
            if new == .inCall && old != .inCall { return .success }
            if new == .audioPaused && old != .audioPaused { return .warning }
            return nil
        }
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
                .font(AppTypography.destinationTitle)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: AppSpacing.m) {
                if viewModel.standardCallStatus == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusSymbol).foregroundStyle(statusColor).accessibilityHidden(true)
                }
                Text(LocalizedStringKey(viewModel.standardCallStatus.title))
                    .accessibilityIdentifier("standardCallStatus")
            }.font(.title3.weight(.semibold))
            statusDetail
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 0 : AppSpacing.m)
        .appCallHeroStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("standardCallHero")
    }

    private func accessibleCompactHero(_ group: IntercomGroup) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.screen) {
            Label {
                Text(viewModel.callTitle(for: group)).lineLimit(2).accessibilityAddTraits(.isHeader)
            } icon: {
                Image(systemName: group.kind == .group ? "person.3.fill" : "person.fill")
                    .foregroundStyle(AppColorPalette.buttonProminentBackground)
            }
            .font(AppTypography.destinationTitle)
            Spacer(minLength: 0)
            HStack {
                if viewModel.standardCallStatus == .connecting { ProgressView().controlSize(.small) }
                else { Image(systemName: statusSymbol).foregroundStyle(statusColor).accessibilityHidden(true) }
                VStack(alignment: .leading) {
                    Text(LocalizedStringKey(viewModel.standardCallStatus.title))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("standardCallStatus")
                    statusDetail
                }
            }
            .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .appCallHeroStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("standardCallHero")
    }

    @ViewBuilder private func detailSections(_ group: IntercomGroup) -> some View {
        if group.kind == .direct {
            Section { Text("Share the invitation from More the first time. Your friend needs to open this call too; this does not send a notification.")
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
                    }
                    .frame(minHeight: 44)
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
                .memberRowActions(edit: { editingMember = .init(groupID: group.id, member: member) },
                                  canDelete: group.kind == .group) { viewModel.removeMember(member.id, from: group.id) }
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

    /// The reason sits on its own line under the state instead of after a dash.
    @ViewBuilder private var statusDetail: some View {
        if let detail = viewModel.standardCallStatus.detail {
            Text(LocalizedStringKey(detail))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("standardCallStatusDetail")
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

    private var microphoneStatus: some View {
        Text(LocalizedStringKey(viewModel.isMuted ? "Microphone muted" : viewModel.isMicrophoneCaptureRunning ? "Microphone on" : "Microphone waiting for the call"))
            .font(.footnote).accessibilityIdentifier("standardMicrophoneStatus")
    }

    @ViewBuilder private func primaryActions(_ group: IntercomGroup, compact: Bool, showsStatus: Bool = true) -> some View {
        let reference = viewModel.currentCallReference
        let access = viewModel.accountAccessID
        if group.id == viewModel.activeGroupID, viewModel.hasAnyActiveGroupConnection {
            let diameter = compact ? AppSize.callControlCompactDiameter : AppSize.callControlDiameter
            GlassEffectContainer(spacing: AppSpacing.callControls) {
                ViewThatFits(in: .horizontal) {
                    controlRow(reference: reference, diameter: diameter, vertical: false, horizontalLabels: compact && dynamicTypeSize.isAccessibilitySize)
                    controlRow(reference: reference, diameter: diameter, vertical: true, horizontalLabels: compact && dynamicTypeSize.isAccessibilitySize)
                }
            }
            .frame(maxWidth: .infinity)
            if showsStatus && viewModel.canControlMicrophone { microphoneStatus }
        } else {
            Button(LocalizedStringKey(viewModel.hasAnyActiveGroupConnection ? "Switch to This Call" : "Connect"), systemImage: "phone") {
                viewModel.startCall(to: .group(group.id), accountAccessID: access)
            }
            .appProminentButtonStyle()
            .disabled(!viewModel.canStartCalls)
            .accessibilityIdentifier("standardConnectButton")
        }
    }

    private func controlRow(reference: CallReference, diameter: CGFloat, vertical: Bool, horizontalLabels: Bool) -> some View {
        let controlLayout = horizontalLabels ? AnyLayout(HStackLayout(spacing: AppSpacing.xs)) : AnyLayout(VStackLayout(spacing: AppSpacing.m))
        let layout = vertical ? AnyLayout(VStackLayout(spacing: AppSpacing.m)) : AnyLayout(HStackLayout(alignment: .top, spacing: AppSpacing.callControls))
        return layout {
            if viewModel.canControlMicrophone {
                controlLayout {
                    Button { viewModel.setCallMuted(!viewModel.isMuted, for: reference) } label: {
                        Image(systemName: "mic.slash").frame(width: diameter, height: diameter)
                    }
                    .modifier(CallMuteButtonStyle(isMuted: viewModel.isMuted))
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Mute Microphone")
                    .accessibilityValue(viewModel.isMuted ? "Muted" : "Unmuted")
                    .accessibilityAddTraits(viewModel.isMuted ? .isSelected : [])
                    .accessibilityIdentifier("standardMuteButton")
                    Text(viewModel.isMuted ? "Muted" : "Mute")
                        .font(AppTypography.footnoteStrong)
                        .fixedSize(horizontal: horizontalLabels, vertical: true)
                        .accessibilityIdentifier("standardMuteState")
                }
            } else {
                Label("Control the microphone on your Watch", systemImage: "applewatch")
                    .font(.caption).accessibilityIdentifier("standardMicrophoneStatus")
            }
            controlLayout {
                Button { viewModel.toggleOutputMute() } label: {
                    Image(systemName: "speaker.slash").frame(width: diameter, height: diameter)
                }
                .modifier(CallMuteButtonStyle(isMuted: viewModel.isOutputMuted, tint: AppColorPalette.buttonProminentBackground))
                .buttonBorderShape(.circle)
                .accessibilityLabel("Mute Speaker")
                .accessibilityValue(viewModel.isOutputMuted ? "Muted" : "Unmuted")
                .accessibilityAddTraits(viewModel.isOutputMuted ? .isSelected : [])
                .accessibilityIdentifier("standardSpeakerButton")
                Text("Speaker").font(AppTypography.footnoteStrong)
                    .fixedSize(horizontal: horizontalLabels, vertical: true)
                    .accessibilityIdentifier("standardSpeakerControlLabel")
            }
            controlLayout {
                Button(role: .destructive) { pendingEndReference = reference; confirmsEnd = true } label: {
                    Image(systemName: "phone.down.fill").frame(width: diameter, height: diameter)
                }
                .buttonStyle(.glassProminent).tint(AppColorPalette.danger)
                .buttonBorderShape(.circle)
                .accessibilityLabel("End Call")
                .accessibilityIdentifier("standardEndCallButton")
                Text("End").font(AppTypography.footnoteStrong)
                    .fixedSize(horizontal: horizontalLabels, vertical: true)
                    .accessibilityIdentifier("standardEndControlLabel")
            }.padding(.leading, vertical ? 0 : max(0, AppSpacing.destructiveSeparation - AppSpacing.callControls))
        }
    }

    private var audioDetails: some View {
        Section("Audio") {
            VStack(alignment: .leading) {
                HStack {
                    Text("Speaker Volume").accessibilityIdentifier("standardSpeakerVolumeLabel")
                    Spacer()
                    Text("\(Int(viewModel.masterOutputVolume * 100))%")
                        .monospacedDigit().accessibilityIdentifier("standardSpeakerVolumeValue")
                }
                Slider(value: Binding(get: { Double(viewModel.masterOutputVolume) }, set: { viewModel.setMasterOutputVolume(Float($0)) }), in: 0...2) {
                    Text("Speaker Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3")
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
    var tint: Color = AppColorPalette.danger
    @ViewBuilder func body(content: Content) -> some View {
        if isMuted {
            content.buttonStyle(.glassProminent).tint(tint)
        } else {
            content.buttonStyle(.glass)
        }
    }
}
