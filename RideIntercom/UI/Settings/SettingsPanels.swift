import SwiftUI
import RTC
import Codec

struct CallDisconnectTimerSection: View {
    let viewModel: IntercomViewModel

    var body: some View {
        Section {
            Picker("Regular Calls", selection: Binding(get: { viewModel.callDisconnectInterval },
                                                       set: { viewModel.setCallDisconnectInterval($0) })) {
                ForEach(CallDisconnectInterval.allCases) { interval in Text(interval.title).tag(interval) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("callDisconnectIntervalPicker")
            Picker("Calls Started from Watch", selection: Binding(get: { viewModel.watchCallDisconnectInterval },
                                                                 set: { viewModel.setCallDisconnectInterval($0, usingWatch: true) })) {
                ForEach(CallDisconnectInterval.allCases) { interval in Text(interval.title).tag(interval) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("watchCallDisconnectIntervalPicker")
        } header: {
            Text("Automatic Disconnection")
        } footer: {
            Text("Applies when starting a new call. Waiting and reconnecting count toward this time. You can start another call after the timer ends it.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("callDisconnectTimerSection")
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
            Text("Communication")
                .accessibilityIdentifier("communicationPanel")
        } footer: {
            Text("Internet controls this device’s service connection. Nearby riders can relay calls for riders with Internet off. Relay uses battery and data. Changing these settings ends the current connection; connect again to apply them.")
                .font(.footnote)
        }
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
            Text("Audio Session")
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
                .disabled(viewModel.audioCheckPhase.isInProgress)
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
                .disabled(viewModel.audioCheckPhase.isInProgress)
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
            Text("Audio I/O")
        }
        .accessibilityIdentifier("audioIOPanel")
    }
}

struct TransmitCodecPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Codec")
                    .accessibilityIdentifier("transmitCodecLabel")
                Picker("Codec", selection: Binding(
                    get: { viewModel.preferredTransmitCodec },
                    set: { viewModel.setPreferredTransmitCodec($0) }
                )) {
                    Text("PCM 16-bit").tag(AudioCodecIdentifier.pcm16)
                    Text("AAC-ELD").tag(AudioCodecIdentifier.mpeg4AACELD)
                    Text("Opus").tag(AudioCodecIdentifier.opus)
                }
                .pickerStyle(.segmented)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transmitCodecPicker")
            }

            VStack(alignment: .leading) {
                Text("Sample Rate")
                    .accessibilityIdentifier("rtcAudioSampleRateLabel")
                Picker("Sample Rate", selection: Binding(
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
            }

            if viewModel.preferredTransmitCodec == .mpeg4AACELD {
                Picker("AAC-ELD Bitrate", selection: Binding(
                        get: { viewModel.aacELDv2BitRate },
                        set: { viewModel.setAACELDv2BitRate($0) }
                    )) {
                    ForEach(viewModel.availableAACBitRates, id: \.self) { bitRate in
                        if AppAudioCodecBridge.isLowBandwidthAACBitRate(bitRate, format: viewModel.rtcAudioFormatPreset.audioFormat) {
                            Text("\(bitRate / 1_000) kbps (Lower Quality)").tag(bitRate)
                        } else {
                            Text("\(bitRate / 1_000) kbps").tag(bitRate)
                        }
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("aacELDBitRatePicker")
            }

            if viewModel.preferredTransmitCodec == .opus {
                BitRateStepper(
                    title: "Opus Bitrate",
                    value: Binding(
                        get: { viewModel.opusBitRate },
                        set: { viewModel.setOpusBitRate($0) }
                    ),
                    choices: viewModel.availableOpusBitRates,
                    accessibilityIdentifier: "opusBitRateStepper"
                )
            }
        } header: {
            Text("Transmit Codec")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if viewModel.preferredTransmitCodec == .opus {
                    Text("Opus 24 and 32 kbps are lower-quality options. The default remains 48 kbps. Encoding bitrate is not total network usage.")
                        .accessibilityIdentifier("opusLowBandwidthExplanation")
                }
                Text("AAC-ELD choices depend on the sample rate. Unsupported values are adjusted to the nearest quality-preserving choice.")
                if viewModel.preferredTransmitCodec == .mpeg4AACELD,
                   viewModel.availableAACBitRates.contains(where: { AppAudioCodecBridge.isLowBandwidthAACBitRate($0, format: viewModel.rtcAudioFormatPreset.audioFormat) }) {
                    Text("48 kHz / 32 kbps and 24 kHz / 16 kbps are lower-quality options. They do not change the default. Encoding bitrate is not total network usage.")
                        .accessibilityIdentifier("aacLowBandwidthExplanation")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transmitCodecPanel")
    }
}

private struct BitRateStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let choices: [Int]
    let accessibilityIdentifier: String

    var body: some View {
        let increment: (() -> Void)? = choices.first(where: { $0 > value }).map { next in { value = next } }
        let decrement: (() -> Void)? = choices.last(where: { $0 < value }).map { previous in { value = previous } }
        Stepper(onIncrement: increment, onDecrement: decrement) {
            LabeledContent(title) {
                if value < 48_000 {
                    Text("\(value / 1_000) kbps (Lower Quality)")
                } else {
                    Text("\(value / 1_000) kbps")
                }
            }
        }
        .accessibilityValue(value < 48_000
            ? Text("\(value / 1_000) kbps (Lower Quality)")
            : Text("\(value / 1_000) kbps"))
        .accessibilityIdentifier(accessibilityIdentifier)
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
                    Text(LocalizedStringKey(sensitivity.label)).tag(sensitivity)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("vadSensitivityPicker")

        } header: {
            Text("Voice Activity")
                .accessibilityIdentifier("voiceActivityPanel")
        }
    }
}

struct ResetSettingsPanel: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var isConfirmingReset = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                Text("Reset All Settings")
            }
            .accessibilityIdentifier("resetAllSettingsButton")
        } footer: {
            Text("Resets audio and call settings to their default values. Saved groups and members are not changed.")
                .accessibilityIdentifier("resetSettingsPanel")
        }
        .alert("Reset All Settings?", isPresented: $isConfirmingReset) {
            Button("Reset All Settings", role: .destructive) {
                viewModel.resetAllSettings()
            }
            .accessibilityIdentifier("confirmResetAllSettingsButton")
            Button("Cancel", role: .cancel) { }
                .accessibilityIdentifier("cancelResetAllSettingsButton")
        } message: {
            Text("Resets audio and call settings to their default values. Saved groups and members are not changed.")
        }
    }
}
