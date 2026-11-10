import SwiftUI
import RTC

struct CallView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        CallHeightLayout { compactHeight, regularWidth in
            GlassEffectContainer(spacing: AppSpacing.screen) {
                if compactHeight || regularWidth {
                    HStack(alignment: .top, spacing: AppSpacing.screen) {
                        ScrollView {
                            primaryColumn.padding(AppSpacing.screen)
                        }
                        .frame(maxWidth: AppSize.callColumnMaxWidth)
                        ScrollView {
                            detailColumn.padding(AppSpacing.screen)
                        }
                        .frame(maxWidth: AppSize.callColumnMaxWidth)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppSpacing.screen) {
                            primaryColumn
                            detailColumn
                        }
                        .padding(AppSpacing.screen)
                        .frame(maxWidth: AppSize.singleColumnMaxWidth)
                    }
                }
            }
        }
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
        .screenBackground(AppColorPalette.listScreenBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("callScreen")
    }

    private var primaryColumn: some View {
        VStack(alignment: .leading, spacing: AppSpacing.screen) {
            if let message = viewModel.groupErrorMessage { AdvancedCallErrorCard(message: message) }
            statusHeader
            controls
                if viewModel.selectedGroup?.kind == .direct {
                    Text(viewModel.selectedGroup.flatMap(viewModel.directCallRecipient) == nil
                         && viewModel.selectedGroup.flatMap(viewModel.directCallAccountRecipient) == nil
                         ? "This user was removed from Saved Users. Your current call stays available until you disconnect."
                         : "Individual call")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("directCallHelpLabel")
                }
                if viewModel.selectedGroup?.id == viewModel.activeGroupID {
                    if let notice = viewModel.connectivityNotice {
                        Label(notice, systemImage: "network")
                            .accessibilityIdentifier("connectivityNotice")
                    }
                    if let notice = viewModel.audioRouteNotice {
                        Label(notice, systemImage: "headphones")
                            .accessibilityIdentifier("audioRouteNotice")
                    }
                    if viewModel.isAudioPausedForDeviceChange, viewModel.canResumeAudioOnThisDevice {
                        Button("Resume Audio", systemImage: "play.fill") {
                            viewModel.resumeAudioAfterDeviceChange()
                        }
                        .controlSize(.large)
                        .buttonStyle(.glassProminent)
                        .disabled(viewModel.authenticatedPeerIDs.isEmpty)
                        .accessibilityIdentifier("resumeAudioButton")
                    }
                }

        }
    }

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: AppSpacing.screen) {
                VStack(alignment: .leading, spacing: AppSpacing.l) {
                    Text("Participants")
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(AppColorPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if remoteMembers.isEmpty {
                    Text("No remote riders")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(AppColorPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appCallCardStyle()
                        .accessibilityIdentifier("emptyRemoteParticipantsLabel")
                } else {
                    VStack(spacing: AppSpacing.l) {
                        ForEach(Array(remoteMembers.enumerated()), id: \.element.id) { index, member in
                            RemoteParticipantRowView(
                                viewModel: viewModel,
                                index: index,
                                member: member
                            )
                            .accessibilityIdentifier("remoteParticipantRow\(index)")
                        }
                    }
                }

                if let audioErrorMessage = viewModel.audioErrorMessage {
                    Text(audioErrorMessage)
                        .font(AppTypography.footnote)
                        .foregroundStyle(AppColorPalette.danger)
                        .accessibilityIdentifier("audioErrorLabel")
                }
        }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxl) {
            HStack(alignment: .center, spacing: AppSpacing.xl) {
                HStack(spacing: AppSpacing.l) {
                    Image(systemName: connectionIconName)
                        .imageScale(.large)
                        .foregroundStyle(connectionStatusColor)
                        .frame(width: AppSize.iconM)

                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(viewModel.callPresenceLabel)
                            .font(AppTypography.rowTitle)
                            .lineLimit(2)
                            .accessibilityIdentifier("callPresenceLabel")
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                            Image(systemName: routeIconName)
                                .foregroundStyle(routeIconColor)
                                .frame(width: AppSize.iconS)

                            Text(viewModel.routeLabel)
                                .font(AppTypography.captionStrong)
                                .foregroundStyle(AppColorPalette.textSecondary)
                                .lineLimit(2)
                                .accessibilityIdentifier("routeLabel")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Call status")
                .accessibilityValue("\(viewModel.callPresenceLabel), \(viewModel.routeLabel)")
                .accessibilityIdentifier("connectionStatusIcon")

                Spacer()
            }

            if let localMember {
                let reference = viewModel.currentCallReference
                let muted = !viewModel.isMuted
                LocalMicrophoneHeaderControl(
                    member: localMember,
                    isMuted: viewModel.effectiveInputMuted,
                    canControlMicrophone: viewModel.canControlMicrophone,
                    onToggleMute: { viewModel.setCallMuted(muted, for: reference) }
                )
            }

            HStack(alignment: .center, spacing: AppSpacing.xl) {
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                        Label("Output", systemImage: "speaker.wave.2.fill")
                            .font(AppTypography.captionStrong)
                            .foregroundStyle(viewModel.isOutputMuted ? AppColorPalette.danger : AppColorPalette.textSecondary)

                        if showsDuckingStatusIcon {
                            Image(systemName: "waveform")
                                .foregroundStyle(duckingStatusIconColor)
                                .frame(width: AppSize.iconS)
                                .accessibilityLabel(duckingStatusAccessibilityLabel)
                                .accessibilityValue(duckingStatusAccessibilityValue)
                                .accessibilityIdentifier("duckingStatusIcon")
                        }
                    }

                    Text(outputStateLabel)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColorPalette.textSecondary)
                        .accessibilityIdentifier("outputStateLabel")

                    Slider(value: Binding(
                        get: { Double(viewModel.masterOutputVolume) },
                        set: { viewModel.setMasterOutputVolume(Float($0)) }
                    ), in: 0...2) {
                        Text("Output Volume")
                    } minimumValueLabel: {
                        Image(systemName: "speaker")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3")
                    }
                    .accessibilityLabel("Output Volume")
                    .accessibilityValue(outputPercentLabel)
                    .accessibilityIdentifier("masterOutputSlider")

                    if viewModel.supportsSoundIsolation {
                        Toggle(isOn: Binding(
                            get: { viewModel.receiveMasterSoundIsolationEnabled },
                            set: { viewModel.setReceiveMasterSoundIsolationEnabled($0) }
                        )) {
                            Label("Voice Isolation", systemImage: "wand.and.sparkles")
                                .font(AppTypography.captionStrong)
                        }
                        .accessibilityLabel("Master Output Voice Isolation Effect")
                        .accessibilityValue(viewModel.receiveMasterSoundIsolationEnabled ? "Enabled" : "Bypassed")
                        .accessibilityIdentifier("masterVoiceIsolationToggle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    viewModel.toggleOutputMute()
                } label: {
                    Image(systemName: viewModel.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: AppSize.tapPrimary.width, height: AppSize.tapPrimary.height)
                }
                .appSecondaryButtonStyle()
                .modifier(AdvancedSelectedControlStyle(isSelected: viewModel.isOutputMuted, tint: AppColorPalette.buttonProminentBackground))
                .accessibilityAddTraits(viewModel.isOutputMuted ? .isSelected : [])
                .accessibilityLabel(viewModel.isOutputMuted ? "Unmute Output" : "Mute Output")
                .accessibilityValue(outputPercentLabel)
                .accessibilityIdentifier("masterOutputMuteButton")
            }
        }
        .appDetailedCallHeroStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("callStatusHeader")
    }

    private var localMember: GroupMember? {
        viewModel.selectedGroup?.members.first
    }

    private var remoteMembers: [GroupMember] {
        Array(viewModel.selectedGroup?.members.dropFirst() ?? [])
    }

    private var outputPercentLabel: String {
        outputStateLabel
    }

    private var outputStateLabel: String {
        viewModel.isOutputMuted ? "Output Muted" : "Output \(Int(viewModel.masterOutputVolume * 100))%"
    }

    private var showsDuckingStatusIcon: Bool {
        viewModel.supportsAdvancedMixingOptions && viewModel.isDuckOthersEnabled
    }

    private var duckingStatusIconColor: Color {
        viewModel.isOtherAudioDuckingActive ? AppColorPalette.info : AppColorPalette.textSecondary
    }

    private var duckingStatusAccessibilityLabel: String {
        "Duck Other Audio"
    }

    private var duckingStatusAccessibilityValue: String {
        viewModel.isOtherAudioDuckingActive ? "Active" : "Enabled"
    }

    private var controls: some View { primaryConnectionButton }

    private var primaryConnectionButton: some View {
        let reference = viewModel.currentCallReference
        let destination = viewModel.selectedGroup.map { CallDestination.group($0.id) }
        let accessID = viewModel.accountAccessID
        return Group {
            if viewModel.canDisconnectCall {
                Button {
                    viewModel.endCall(reference)
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle.fill")
                }
                .tint(AppColorPalette.danger)
                .accessibilityIdentifier("disconnectButton")
            } else {
                Button {
                    if let destination { viewModel.startCall(to: destination, accountAccessID: accessID) }
                } label: {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }
                .accessibilityIdentifier("connectButton")
            }
        }
        .appProminentButtonStyle()
        .controlSize(.large)
        .accessibilityValue(viewModel.callPresenceLabel)
    }

    private var connectionIconName: String {
        return switch viewModel.selectedGroupConnectionState {
        case .idle:
            "wifi.slash"
        case .localConnecting, .internetConnecting:
            "wifi.exclamationmark"
        case .localConnected, .internetConnected:
            "wifi"
        case .reconnectingOffline:
            "exclamationmark.triangle.fill"
        }
    }

    private var connectionStatusColor: Color {
        return switch viewModel.selectedGroupConnectionState {
        case .idle:
            AppColorPalette.neutral
        case .localConnecting, .internetConnecting:
            AppColorPalette.warning
        case .localConnected, .internetConnected:
            AppColorPalette.success
        case .reconnectingOffline:
            AppColorPalette.danger
        }
    }

    private var routeIconName: String {
        switch viewModel.selectedGroupConnectionState {
        case .localConnected, .localConnecting:
            "dot.radiowaves.left.and.right"
        case .internetConnected, .internetConnecting:
            "network"
        case .idle, .reconnectingOffline:
            "network"
        }
    }

    private var routeIconColor: Color {
        AppColorPalette.textSecondary
    }
}
