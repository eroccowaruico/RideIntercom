import SwiftUI
import RTC

struct LocalMicrophoneHeaderControl: View {
    let member: GroupMember
    let isMuted: Bool
    let onToggleMute: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.xl) {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.m) {
                    Label {
                        Text("Input")
                            .font(AppTypography.subheadlineStrong)
                            .foregroundStyle(isMuted ? AppColorPalette.danger : AppColorPalette.textSecondary)
                    } icon: {
                        Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(isMuted ? AppColorPalette.danger : AppColorPalette.textSecondary)
                    }

                    Text(isMuted ? "Muted" : "Unmuted")
                        .font(AppTypography.captionStrongMono)
                        .foregroundStyle(isMuted ? AppColorPalette.danger : AppColorPalette.success)
                        .accessibilityIdentifier("localMicrophoneStateLabel")
                }

                VoiceMeterView(
                    level: isMuted ? 0 : member.voiceLevel,
                    peakLevel: isMuted ? 0 : member.voicePeakLevel,
                    isMuted: isMuted,
                    showsValueText: false
                )
                .accessibilityIdentifier("localMicrophoneMeter")
            }

            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: AppSize.tapPrimary.width, height: AppSize.tapPrimary.height)
            }
            .appSecondaryButtonStyle()
            .tint(isMuted ? AppColorPalette.danger : AppColorPalette.buttonProminentBackground)
            .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            .accessibilityValue(isMuted ? "Muted" : "Unmuted")
            .accessibilityIdentifier("localMicrophoneMuteButton")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your microphone")
        .accessibilityValue(isMuted ? "Muted" : "Unmuted")
        .accessibilityIdentifier("localMicrophoneHeaderControl")
    }
}

struct RemoteParticipantRowView: View {
    @Bindable var viewModel: IntercomViewModel
    let index: Int
    let member: GroupMember

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xl) {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(member.displayName)
                        .font(AppTypography.rowTitle)
                        .lineLimit(2)
                        .accessibilityIdentifier("participantName\(index)")

                    HStack(spacing: AppSpacing.m) {
                        Image(systemName: connectionIconName)
                            .foregroundStyle(connectionIconColor)
                        Image(systemName: authIconName)
                            .foregroundStyle(authIconColor)
                    }
                    .font(AppTypography.footnoteStrong)
                    .accessibilityIdentifier("participantStatusSummary\(index)")
                }

                Spacer()

                VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                    Label(codecLabel, systemImage: audioPipelineIconName)
                        .font(AppTypography.caption)
                        .foregroundStyle(audioPipelineColor)

                }
                .accessibilityIdentifier("participantAudioPipelineState\(index)")
            }

            VStack(alignment: .leading, spacing: AppSpacing.l) {
                participantMeter
                participantOutputControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCallCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(member.displayName)
        .accessibilityValue("\(statusSummary), \(codecLabel)")
    }

    private var participantMeter: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Label("Input", systemImage: member.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(AppTypography.captionStrong)
                .foregroundStyle(member.isMuted ? AppColorPalette.danger : AppColorPalette.textSecondary)

            VoiceMeterView(
                level: member.isMuted ? 0 : member.voiceLevel,
                peakLevel: member.isMuted ? 0 : member.voicePeakLevel,
                isMuted: member.isMuted,
                showsValueText: false
            )
        }
        .accessibilityIdentifier("participantVoiceLevel\(index)")
    }

    private var participantOutputControls: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                Label("Output", systemImage: "speaker.wave.2.fill")
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AppColorPalette.textSecondary)

                Text(participantOutputPercentLabel)
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(AppColorPalette.textSecondary)
                    .accessibilityIdentifier("participantOutputValue\(index)")
            }

            Slider(
                value: Binding(
                    get: { Double(viewModel.remoteOutputVolume(for: member.id)) },
                    set: { viewModel.setRemoteOutputVolume(peerID: member.id, volume: Float($0)) }
                ),
                in: 0...1
            )
            .accessibilityLabel("\(member.displayName) Output")
            .accessibilityValue(participantOutputPercentLabel)
            .accessibilityIdentifier("participantOutputSlider\(index)")

            if viewModel.supportsSoundIsolation {
                Toggle(isOn: Binding(
                    get: { viewModel.isRemoteSoundIsolationEnabled(peerID: member.id) },
                    set: { viewModel.setRemoteSoundIsolationEnabled(peerID: member.id, enabled: $0) }
                )) {
                    Label("Voice Isolation", systemImage: "wand.and.sparkles")
                        .font(AppTypography.captionStrong)
                }
                .accessibilityLabel("\(member.displayName) Voice Isolation Effect")
                .accessibilityValue(viewModel.isRemoteSoundIsolationEnabled(peerID: member.id) ? "Enabled" : "Bypassed")
                .accessibilityIdentifier("participantVoiceIsolationToggle\(index)")
            }
        }
        .accessibilityIdentifier("participantOutputControls\(index)")
    }

    private var statusSummary: String {
        "\(member.connectionState.rawValue) / \(authenticationLabel) / \(member.audioPipelineState.rawValue)"
    }

    private var connectionIconName: String {
        switch member.connectionState {
        case .connected:
            "wifi"
        case .connecting:
            "wifi.exclamationmark"
        case .offline:
            "wifi.slash"
        }
    }

    private var connectionIconColor: Color {
        switch member.connectionState {
        case .connected:
            AppColorPalette.success
        case .connecting:
            AppColorPalette.warning
        case .offline:
            AppColorPalette.neutral
        }
    }

    private var authIconName: String {
        switch member.authenticationState {
        case .open:
            "lock.open"
        case .pending:
            "clock.badge.questionmark"
        case .authenticated:
            "checkmark.seal.fill"
        case .offline:
            "xmark.seal"
        }
    }

    private var authIconColor: Color {
        switch member.authenticationState {
        case .open:
            AppColorPalette.neutral
        case .pending:
            AppColorPalette.warning
        case .authenticated:
            AppColorPalette.success
        case .offline:
            AppColorPalette.danger
        }
    }

    private var authenticationLabel: String {
        switch member.authenticationState {
        case .open:
            "Open"
        case .pending:
            "Auth Pending"
        case .authenticated:
            "Auth OK"
        case .offline:
            "Auth Off"
        }
    }

    private var participantOutputPercentLabel: String {
        "Output \(Int(viewModel.remoteOutputVolume(for: member.id) * 100))%"
    }

    private var codecLabel: String {
        guard let codec = member.activeCodec else { return "--" }
        if codec == .pcm16 { return "PCM 16-bit" }
        if codec == .mpeg4AACELDv2 { return "AAC-ELD v2" }
        if codec == .opus { return "Opus" }
        return codec.rawValue
    }

    private var audioPipelineIconName: String {
        "cpu"
    }

    private var audioPipelineColor: Color {
        switch member.audioPipelineState {
        case .receiving:
            AppColorPalette.info
        case .playing:
            AppColorPalette.success
        case .received:
            AppColorPalette.warning
        case .idle:
            AppColorPalette.neutral
        }
    }
}

struct GroupRowView: View {
    let title: String
    let subtitle: String
    let iconColor: Color

    var body: some View {
        HStack(spacing: AppSpacing.xl) {
            Image(systemName: "person.3")
                .foregroundStyle(iconColor)
                .frame(width: AppSize.iconM)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(AppTypography.rowTitle)
                    .lineLimit(2)
                Text(subtitle)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColorPalette.textSecondary)
            }

            Spacer(minLength: AppSpacing.xl)

            Image(systemName: "chevron.right")
                .font(AppTypography.footnoteStrong)
                .foregroundStyle(AppColorPalette.textTertiary)
        }
        .appCallCardStyle()
        .contentShape(Rectangle())
    }
}
