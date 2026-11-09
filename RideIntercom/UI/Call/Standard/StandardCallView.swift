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
                        primaryActions(group, compact: true)
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
                        // The glass card is its own section's row background: it lines up with the sections
                        // below, and the section's rounded clip falls on the card's edge.
                        Section {
                            hero(group, compact: false, card: false)
                                .padding(.vertical, AppSpacing.xs)
                                .listRowBackground(StandardHeroCard.surface)
                                .listRowSeparator(.hidden)
                        }
                        Section {
                            primaryActions(group, compact: false)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        detailSections(group)
                    }
                    CallErrorSection(viewModel: viewModel)
                }
                // The hero sits right under the sheet's toolbar, as in the design sample.
                .contentMargins(.top, AppSpacing.s, for: .scrollContent)
                #if os(iOS)
                .listSectionSpacing(.compact)
                #endif
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

    /// The status hero: a glass card, leading-aligned, with the kind and size, the destination,
    /// the state and its reason. The route is not shown. VoiceOver reads it as one element.
    private func hero(_ group: IntercomGroup, compact: Bool, card: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: compact ? AppSpacing.xxs : AppSpacing.xs) {
            // At accessibility sizes the state must stay on screen with the controls.
            if !(compact && dynamicTypeSize.isAccessibilitySize) { kindLine(group) }
            Text(viewModel.callTitle(for: group))
                .font(AppTypography.destinationTitle)
                .lineLimit(2)
            // Words are never broken: when the symbol and state do not fit side by side, stack them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.s) { statusSymbolView; statusTitle }
                VStack(alignment: .leading, spacing: AppSpacing.xs) { statusSymbolView; statusTitle }
            }
            .font(.title3.weight(.semibold))
            .padding(.top, AppSpacing.xxs)
            statusDetail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StandardHeroCard(drawsSurface: card))
        .standardHeroAccessibility(kind: kindText(group), name: viewModel.callTitle(for: group),
                                   status: viewModel.standardCallStatus)
    }

    /// Landscape at accessibility sizes: name and state side by side so the controls keep their room.
    private func accessibleCompactHero(_ group: IntercomGroup) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.screen) {
            Text(viewModel.callTitle(for: group))
                .font(AppTypography.destinationTitle)
                .lineLimit(2)
            Spacer(minLength: 0)
            HStack {
                statusSymbolView
                VStack(alignment: .leading) {
                    statusTitle
                    statusDetail
                }
            }
            .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StandardHeroCard())
        .standardHeroAccessibility(kind: kindText(group), name: viewModel.callTitle(for: group),
                                   status: viewModel.standardCallStatus)
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
                        // Color never carries "speaking" alone: the symbol has a label.
                        if group.id == viewModel.activeGroupID, member.isTalking {
                            Image(systemName: "waveform")
                                .foregroundStyle(AppColorPalette.voiceLevel)
                                .accessibilityLabel("Speaking")
                                .accessibilityIdentifier("standardMemberSpeaking-\(member.id)")
                        }
                    }
                    .frame(minHeight: 44)
                    if group.id == viewModel.activeGroupID, viewModel.authenticatedPeerIDs.contains(member.id) {
                        VStack(alignment: .leading) {
                            Text("Volume").accessibilityIdentifier("standardPeerVolumeLabel-\(member.id)")
                            Slider(value: Binding(get: { Double(viewModel.remoteOutputVolume(for: member.id)) },
                                                  set: { viewModel.setRemoteOutputVolume(peerID: member.id, volume: Float($0)) }), in: 0...1) {
                                Text("Volume for \(member.resolvedDisplayName)")
                            }
                            .labelsHidden()
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

    @ViewBuilder private var statusSymbolView: some View {
        if viewModel.standardCallStatus == .connecting {
            // Only the progress carries the warning color; the words keep the label color.
            ProgressView().controlSize(.small).tint(AppColorPalette.warning)
        } else {
            Image(systemName: statusSymbol).foregroundStyle(statusColor)
        }
    }

    private var statusTitle: some View {
        Text(LocalizedStringKey(viewModel.standardCallStatus.title))
            .fixedSize()
    }

    private func kindText(_ group: IntercomGroup) -> String {
        group.kind == .group ? String(localized: "Group · \(group.members.count) people") : String(localized: "User")
    }

    /// Kind and size above the name with the kind's symbol: "Group · 4 people" or "User".
    private func kindLine(_ group: IntercomGroup) -> some View {
        Label(kindText(group), systemImage: group.kind == .group ? "person.3.fill" : "person.fill")
            .font(AppTypography.subheadlineStrong)
            .foregroundStyle(.secondary)
    }

    /// The reason sits on its own line under the state instead of after a dash.
    @ViewBuilder private var statusDetail: some View {
        if let detail = viewModel.standardCallStatus.detail {
            Text(LocalizedStringKey(detail))
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                    controlRow(reference: reference, diameter: diameter, vertical: false, horizontalLabels: compact && dynamicTypeSize.isAccessibilitySize)
                    controlRow(reference: reference, diameter: diameter, vertical: true, horizontalLabels: compact && dynamicTypeSize.isAccessibilitySize)
                }
            }
            .frame(maxWidth: .infinity)
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
                .labelsHidden()
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

/// The hero's glass card. Standard only: Advanced draws its own call status.
private struct StandardHeroCard: ViewModifier {
    /// In a List the card is drawn as the row background instead (`surface`).
    var drawsSurface = true

    /// In a List the glass follows the section's corners. Elsewhere there is no container to be
    /// concentric with, so it uses the design sample's 18pt continuous corners.
    static var surface: some View { glass(in: ConcentricRectangle()) }

    private static func glass(in shape: some Shape) -> some View {
        shape.fill(.clear)
            #if os(macOS)
            // On Mac the hero is the one place that carries a faint brand tint.
            .glassEffect(.regular.tint(RideComColors.accent.opacity(0.08)), in: shape)
            #else
            .glassEffect(.regular, in: shape)
            #endif
    }

    func body(content: Content) -> some View {
        if drawsSurface {
            content.padding(AppSpacing.xxl)
                .background(Self.glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous)))
        } else {
            content
        }
    }
}

private extension View {
    /// One element: the label names the destination, the value is the state and its reason.
    func standardHeroAccessibility(kind: String, name: String, status: StandardCallStatus) -> some View {
        let state = String(localized: .init(stringLiteral: status.title))
        let reason = status.detail.map { String(localized: .init(stringLiteral: $0)) }
        return accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(kind), \(name)"))
            .accessibilityValue(Text(verbatim: [state, reason].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("standardCallHero")
    }
}
