import SwiftUI
import RTC
import Codec

struct SettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var isEditingInternet = false

    var body: some View {
        Form {
            AccountSettingsPanel(account: viewModel.accountSession)
            CommunicationPanel(viewModel: viewModel)
            InternetConnectionPanel(viewModel: viewModel, isEditing: $isEditingInternet)
            AudioSessionPanel(viewModel: viewModel)
            AudioIOPanel(viewModel: viewModel)
            AudioCheckPanel(viewModel: viewModel)
            TransmitCodecPanel(viewModel: viewModel)
            VoiceActivityPanel(viewModel: viewModel)
            ResetSettingsPanel(viewModel: viewModel)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settingsScrollView")
        .sheet(isPresented: $isEditingInternet) {
            NavigationStack {
                InternetConnectionEditor(viewModel: viewModel)
                    .navigationTitle("Internet Connection")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { isEditingInternet = false }
                                .accessibilityIdentifier("closeInternetConnection")
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 320)
            #endif
        }
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
            Text("Internet controls this device’s service connection. Nearby riders can relay calls for riders with Internet off. Relay uses battery and data. Changing these settings ends the current connection; connect again to apply them.")
                .font(.footnote)
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
                        Text("\(bitRate / 1_000) kbps").tag(bitRate)
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
                    range: Codec.OpusOptions.allowedBitRateRange,
                    step: 2_000,
                    accessibilityIdentifier: "opusBitRateStepper"
                )
            }
        } header: {
            Label("Transmit Codec", systemImage: "antenna.radiowaves.left.and.right")
        } footer: {
            Text("AAC-ELD bitrate choices depend on the sample rate. Changing the sample rate adjusts an unsupported bitrate to the nearest supported value.")
        }
        .accessibilityElement(children: .contain)
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
                    Text(viewModel.connectionLabel)
                        .font(AppTypography.bodyStrong)
                        .foregroundStyle(AppColorPalette.textPrimary)
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

            if viewModel.audioCheckPhase == .recording || viewModel.audioCheckPhase == .playing {
                Button("Stop Audio Check") { viewModel.cancelAudioCheck() }
                    .accessibilityIdentifier("stopAudioCheckButton")
            }

            Button {
                viewModel.startAudioCheck()
            } label: {
                Label("Record 5s and Play", systemImage: "record.circle.fill")
            }
            .appProminentButtonStyle()
            .controlSize(.large)
            .disabled(!viewModel.canStartAudioCheck)
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

struct InternetConnectionPanel: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var isEditing: Bool
    var body: some View {
        Section {
            Text(viewModel.hasInternetCredentials ? "Device token configured" : "Not configured")
                .accessibilityIdentifier("internetConfigurationStatus")
            Button("Configure Internet Connection") { isEditing = true }
                .accessibilityIdentifier("configureInternetConnection")
        } header: { Label("Internet Connection", systemImage: "globe") }
        footer: { Text("Set the service URL and this device's access token before trying Internet calling.") }
    }
}

private struct InternetConnectionEditor: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var workerURL = ""
    @State private var token = ""
    @State private var status = ""
    private enum Field: Hashable { case url, token }
    @FocusState private var focusedField: Field?
    var body: some View {
        Form {
            Section {
                TextField("Worker URL", text: $workerURL)
                    .focused($focusedField, equals: .url)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("internetWorkerURL")
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Device access token", text: $token)
                    .focused($focusedField, equals: .token)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("internetDeviceToken")
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Save Internet Connection") {
                    focusedField = nil
                    do {
                        try viewModel.saveInternetConnection(url: workerURL, token: token)
                        token = ""
                        status = "Saved. Use Check Internet Service in Diagnostics before connecting."
                    } catch {
                        status = "Could not save. Check the HTTPS URL, device token, and Keychain access."
                    }
                }
                .disabled(workerURL.isEmpty || token.isEmpty)
                .accessibilityIdentifier("saveInternetConnection")
                if !status.isEmpty { Text(status).font(.footnote) }
            } header: { Label("Internet Connection", systemImage: "globe") }
            footer: { Text("Use your service URL and device token. Saving ends the current call. Cloudflare account secrets stay on the server.") }
            .onAppear {
                workerURL = viewModel.internetWorkerURL
                if viewModel.hasInternetCredentials { status = "A device token is configured." }
            }
        }
    }
}
