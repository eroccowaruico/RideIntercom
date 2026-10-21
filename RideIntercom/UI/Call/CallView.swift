import SwiftUI
import RTC

struct CallView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.screen) {
                statusHeader
                controls

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
                            .appDeleteActions {
                                removeMember(member.id)
                            }
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
            .padding(AppSpacing.screen)
        }
        .background(AppColorPalette.callScreenBackground)
        .accessibilityIdentifier("callScreen")
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
                LocalMicrophoneHeaderControl(
                    member: localMember,
                    isMuted: viewModel.isMuted,
                    showsMeter: viewModel.supportsPacketAudioControls,
                    onToggleMute: { viewModel.toggleMute() }
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

                    if viewModel.supportsPacketAudioControls {
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.masterOutputVolume) },
                            set: { viewModel.setMasterOutputVolume(Float($0)) }
                        ),
                        in: 0...2
                    )
                    .accessibilityLabel("Output Volume")
                    .accessibilityValue(outputPercentLabel)
                    .accessibilityIdentifier("masterOutputSlider")
                    }

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
                .tint(viewModel.isOutputMuted ? AppColorPalette.danger : AppColorPalette.buttonProminentBackground)
                .accessibilityLabel(viewModel.isOutputMuted ? "Unmute Output" : "Mute Output")
                .accessibilityValue(outputPercentLabel)
                .accessibilityIdentifier("masterOutputMuteButton")
            }
        }
        .appCallCardStyle()
        .accessibilityIdentifier("callStatusHeader")
    }

    private var localMember: GroupMember? {
        viewModel.selectedGroup?.members.first
    }

    private var remoteMembers: [GroupMember] {
        Array(viewModel.selectedGroup?.members.dropFirst() ?? [])
    }

    private func removeMember(_ memberID: GroupMember.ID) {
        guard let selectedGroup = viewModel.selectedGroup else { return }
        viewModel.removeMember(memberID, from: selectedGroup.id)
    }

    private var outputPercentLabel: String {
        outputStateLabel
    }

    private var outputStateLabel: String {
        viewModel.isOutputMuted ? "Output Muted" : (viewModel.supportsPacketAudioControls ? "Output \(Int(viewModel.masterOutputVolume * 100))%" : "System volume")
    }

    private var showsDuckingStatusIcon: Bool {
        viewModel.supportsPacketAudioControls && viewModel.supportsAdvancedMixingOptions && viewModel.isDuckOthersEnabled
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

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlStack(horizontal: true)
            controlStack(horizontal: false)
        }
    }

    private var primaryConnectionButton: some View {
        Group {
            if viewModel.canDisconnectCall {
                Button {
                    viewModel.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle.fill")
                }
                .tint(AppColorPalette.danger)
                .accessibilityIdentifier("disconnectButton")
            } else {
                Button {
                    viewModel.connectLocal()
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

    private func inviteLink(_ inviteURL: URL) -> some View {
        ShareLink(
            item: inviteURL,
            subject: Text("RideIntercom Invite"),
            message: Text("Join \(viewModel.selectedGroup?.name ?? "RideIntercom")")
        ) {
            Label("Invite", systemImage: "square.and.arrow.up")
        }
        .appSecondaryButtonStyle()
        .controlSize(.large)
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.reserveInviteMemberSlot()
        })
        .accessibilityLabel("Invite Group")
        .accessibilityHint("Opens sharing options for this group invite.")
        .accessibilityIdentifier("inviteButton")
    }

    @ViewBuilder
    private func controlStack(horizontal: Bool) -> some View {
        let spacing = AppSpacing.l
        Group {
            if horizontal {
                HStack(spacing: spacing) {
                    primaryConnectionButton
                    inviteAction
                }
            } else {
                VStack(alignment: .leading, spacing: spacing) {
                    primaryConnectionButton
                    inviteAction
                }
            }
        }
    }

    @ViewBuilder
    private var inviteAction: some View {
        if let inviteURL = viewModel.selectedGroupInviteURL {
            inviteLink(inviteURL)
        }
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
