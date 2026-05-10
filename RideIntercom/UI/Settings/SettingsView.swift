import SwiftUI
import RTC

struct SettingsView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Form {
            CommunicationPanel(viewModel: viewModel)
            AudioSessionPanel(viewModel: viewModel)
            AudioIOPanel(viewModel: viewModel)
            AudioCheckPanel(viewModel: viewModel)
            TransmitCodecPanel(viewModel: viewModel)
            VoiceActivityPanel(viewModel: viewModel)
            ResetSettingsPanel(viewModel: viewModel)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settingsScrollView")
    }
}

struct CommunicationPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            Toggle(
                "Local Network",
                isOn: Binding(
                    get: { viewModel.isRTCTransportRouteEnabled(.multipeer) },
                    set: { viewModel.setRTCTransportRoute(.multipeer, enabled: $0) }
                )
            )
            .disabled(!viewModel.canToggleRTCTransportRoute(.multipeer))
            .accessibilityIdentifier("localNetworkRouteToggle")

            Toggle(
                "Internet",
                isOn: Binding(
                    get: { viewModel.isRTCTransportRouteEnabled(.webRTC) },
                    set: { viewModel.setRTCTransportRoute(.webRTC, enabled: $0) }
                )
            )
            .disabled(!viewModel.canToggleRTCTransportRoute(.webRTC))
            .accessibilityIdentifier("internetRouteToggle")
        } header: {
            Label("Communication", systemImage: "network")
        } footer: {
            Text("At least one route stays enabled. Changing routes stops the active RTC connection.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("communicationPanel")
    }
}

struct AudioSessionPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { viewModel.audioSessionModeProfile },
                set: { viewModel.setAudioSessionModeProfile($0) }
            )) {
                ForEach(AudioSessionProfile.settingsModeCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("audioSessionProfilePicker")

            Toggle(
                "Use Speaker",
                isOn: Binding(
                    get: { viewModel.isSpeakerOutputEnabled },
                    set: { viewModel.setSpeakerOutputEnabled($0) }
                )
            )
            .accessibilityIdentifier("speakerOutputToggle")

            if viewModel.audioSessionModeProfile == .standard {
                Toggle(
                    "Echo Cancellation",
                    isOn: Binding(
                        get: { viewModel.isSessionEchoCancellationEnabled },
                        set: { viewModel.setSessionEchoCancellationEnabled($0) }
                    )
                )
                .disabled(!viewModel.canToggleSessionEchoCancellation)
                .accessibilityIdentifier("echoCancellationToggle")
            }

            if viewModel.supportsAdvancedMixingOptions {
                Toggle(
                    "Duck Other Audio",
                    isOn: Binding(
                        get: { viewModel.isDuckOthersEnabled },
                        set: { viewModel.setDuckOthersEnabled($0) }
                    )
                )
                .accessibilityIdentifier("duckOthersToggle")
            }

        } header: {
            Label("Audio Session", systemImage: "slider.horizontal.3")
        } footer: {
            Text("Burst mode uses the default session for intercom-style audio and explicit echo cancellation. Stream mode uses voice-chat routing for continuous conversation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("audioSessionModeDescription")
        }
        .accessibilityIdentifier("audioSessionPanel")
    }
}

struct AudioIOPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            if viewModel.availableOutputPorts.count > 1 {
                AudioPortPicker(
                    title: "Output",
                    selection: Binding(
                        get: { viewModel.selectedOutputPort },
                        set: { viewModel.setOutputPort($0) }
                    ),
                    ports: viewModel.availableOutputPorts,
                    accessibilityIdentifier: "audioCheckOutputPicker"
                )
            }

            if viewModel.availableInputPorts.count > 1 {
                AudioPortPicker(
                    title: "Input",
                    selection: Binding(
                        get: { viewModel.selectedInputPort },
                        set: { viewModel.setInputPort($0) }
                    ),
                    ports: viewModel.availableInputPorts,
                    accessibilityIdentifier: "audioCheckInputPicker"
                )
            }

            if viewModel.supportsSoundIsolation {
                Toggle(
                    "Transmit Voice Isolation Effect",
                    isOn: Binding(
                        get: { viewModel.isSoundIsolationEnabled },
                        set: { viewModel.setSoundIsolationEnabled($0) }
                    )
                )
                .accessibilityIdentifier("soundIsolationToggle")
            }
        } header: {
            Label("Audio I/O", systemImage: "waveform")
        }
        .accessibilityIdentifier("audioIOPanel")
    }
}

struct TransmitCodecPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            Picker("Codec", selection: Binding(
                get: { viewModel.preferredTransmitCodec },
                set: { viewModel.setPreferredTransmitCodec($0) }
            )) {
                Text("PCM 16-bit").tag(AudioCodecIdentifier.pcm16)
                Text("AAC-ELD v2").tag(AudioCodecIdentifier.mpeg4AACELDv2)
                Text("Opus").tag(AudioCodecIdentifier.opus)
            }
            .pickerStyle(.segmented)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transmitCodecPicker")

            Picker("RTC Audio", selection: Binding(
                get: { viewModel.rtcAudioFormatPreset },
                set: { viewModel.setRTCAudioFormatPreset($0) }
            )) {
                ForEach(RTCAudioFormatPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rtcAudioFormatPicker")

            if viewModel.preferredTransmitCodec == .mpeg4AACELDv2 {
                BitRateStepper(
                    title: "AAC-ELD v2 Bitrate",
                    value: Binding(
                        get: { viewModel.aacELDv2BitRate },
                        set: { viewModel.setAACELDv2BitRate($0) }
                    ),
                    range: 12_000...128_000,
                    step: 4_000,
                    accessibilityIdentifier: "aacELDv2BitRateStepper"
                )
            }

            if viewModel.preferredTransmitCodec == .opus {
                BitRateStepper(
                    title: "Opus Bitrate",
                    value: Binding(
                        get: { viewModel.opusBitRate },
                        set: { viewModel.setOpusBitRate($0) }
                    ),
                    range: 6_000...128_000,
                    step: 2_000,
                    accessibilityIdentifier: "opusBitRateStepper"
                )
            }
        } header: {
            Label("Transmit Codec", systemImage: "antenna.radiowaves.left.and.right")
        }
        .accessibilityIdentifier("transmitCodecPanel")
    }
}

private struct BitRateStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let accessibilityIdentifier: String

    var body: some View {
        Stepper(
            value: Binding(
                get: { value },
                set: { value = min(range.upperBound, max(range.lowerBound, $0)) }
            ),
            in: range,
            step: step
        ) {
            LabeledContent(title, value: "\(value / 1_000) kbps")
        }
        .accessibilityValue("\(value / 1_000) kilobits per second")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct AudioCheckPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("Call")
                Spacer()
                VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                    Text(viewModel.isAudioReady ? "Call Live" : "Call Idle")
                        .font(AppTypography.bodyStrong)
                        .foregroundStyle(viewModel.isAudioReady ? AppColorPalette.success : AppColorPalette.textSecondary)
                        .accessibilityIdentifier("liveAudioStateLabel")
                    Text(viewModel.audioCheckPhase.rawValue)
                        .font(AppTypography.captionStrongMono)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("audioCheckPhaseLabel")
                }
            }

            AudioCheckMeterSection(
                title: "Microphone Input",
                systemImage: "mic.fill",
                level: viewModel.diagnosticsInputLevel,
                peakLevel: viewModel.diagnosticsInputPeakLevel,
                isMuted: viewModel.isMuted,
                accessibilityIdentifier: "audioCheckInputMeter"
            )
            .listRowSeparator(.hidden)

            AudioCheckMeterSection(
                title: "Speaker Output",
                systemImage: "speaker.wave.2.fill",
                level: viewModel.diagnosticsOutputLevel,
                peakLevel: viewModel.diagnosticsOutputPeakLevel,
                isMuted: false,
                accessibilityIdentifier: "audioCheckOutputMeter"
            )
            .listRowSeparator(.hidden)

            Text(viewModel.audioCheckStatusMessage)
                .font(AppTypography.footnote)
                .foregroundStyle(AppColorPalette.textSecondary)
                .lineLimit(nil)
                .accessibilityIdentifier("audioCheckStatusLabel")

            Button {
                viewModel.startAudioCheck()
            } label: {
                Label("Record 5s and Play", systemImage: "record.circle.fill")
            }
            .appProminentButtonStyle()
            .controlSize(.large)
            .disabled(viewModel.audioCheckPhase == .recording || viewModel.audioCheckPhase == .playing)
            .accessibilityValue(viewModel.audioCheckPhase.rawValue)
            .accessibilityIdentifier("audioCheckButton")
        } header: {
            Label("Audio Check", systemImage: "waveform")
        }
        .accessibilityIdentifier("audioCheckPanel")
    }

    private var statusColor: Color {
        switch viewModel.audioCheckPhase {
        case .idle:
            AppColorPalette.neutral
        case .recording:
            AppColorPalette.danger
        case .playing:
            AppColorPalette.success
        case .completed:
            AppColorPalette.info
        case .failed:
            AppColorPalette.danger
        }
    }

}

struct VoiceActivityPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            Picker("VAD Sensitivity", selection: Binding(
                get: { viewModel.vadSensitivity },
                set: { viewModel.setVADSensitivity($0) }
            )) {
                ForEach(VoiceActivitySensitivity.allCases) { sensitivity in
                    Text(sensitivity.label).tag(sensitivity)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("vadSensitivityPicker")

        } header: {
            Label("Voice Activity", systemImage: "waveform.badge.mic")
        }
        .accessibilityIdentifier("voiceActivityPanel")
    }
}

struct ResetSettingsPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            Button(role: .destructive) {
                viewModel.resetAllSettings()
            } label: {
                Label("Reset All Settings", systemImage: "arrow.counterclockwise")
            }
            .accessibilityIdentifier("resetAllSettingsButton")
        } footer: {
            Text("Resets audio and call settings to their default values. Saved groups and members are not changed.")
        }
        .accessibilityIdentifier("resetSettingsPanel")
    }
}
