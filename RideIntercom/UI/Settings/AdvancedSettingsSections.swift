import SwiftUI

/// The layout setting as stored: `InterfaceMode`'s two cases side by side.
struct AdvancedInterfaceModeSection: View {
    let viewModel: IntercomViewModel

    var body: some View {
        Section {
            Picker("App Layout", selection: Binding(get: { viewModel.interfaceMode }, set: viewModel.setInterfaceMode)) {
                Text(verbatim: "Standard").tag(InterfaceMode.standard)
                Text(verbatim: "Advanced").tag(InterfaceMode.advanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("interfaceModePicker")
        } header: {
            Text("App Layout")
        } footer: {
            Text("Advanced includes detailed call information and diagnostics. Switching layouts keeps your call connected.")
        }
    }
}

/// The call, the check's phase, the ports it records and plays through, both meters, then the operation.
struct AdvancedAudioCheckPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            // Separate texts, so the call state and the phase each stay readable on their own.
            HStack(alignment: .firstTextBaseline) {
                Text("Call")
                Spacer()
                Text(viewModel.connectionLabel).foregroundStyle(.secondary)
                    .accessibilityIdentifier("liveAudioStateLabel")
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Audio Check")
                Spacer()
                Image(systemName: "circle.fill").foregroundStyle(statusColor).accessibilityHidden(true)
                Text(LocalizedStringKey(viewModel.audioCheckPhase.rawValue))
                    .font(AppTypography.captionStrongMono)
                    .accessibilityIdentifier("audioCheckPhaseLabel")
            }
            LabeledContent("Recording Input") {
                Text(viewModel.isUsingWatchAudio ? "Watch Microphone" : "This Device: \(viewModel.audioCheckInputPortName)")
            }
            .accessibilityIdentifier("audioCheckInputSource")
            LabeledContent("Playback Output") {
                Text(viewModel.isUsingWatchAudio ? "Watch Speaker" : "This Device: \(viewModel.audioCheckOutputPortName)")
            }
            .accessibilityIdentifier("audioCheckOutputDestination")
            AudioCheckMeterSection(title: "Microphone Input", systemImage: "mic.fill",
                                   level: viewModel.diagnosticsInputLevel, peakLevel: viewModel.diagnosticsInputPeakLevel,
                                   isMuted: viewModel.isMuted, accessibilityIdentifier: "audioCheckInputMeter")
                .listRowSeparator(.hidden)
            AudioCheckMeterSection(title: "Speaker Output", systemImage: "speaker.wave.2.fill",
                                   level: viewModel.diagnosticsOutputLevel, peakLevel: viewModel.diagnosticsOutputPeakLevel,
                                   isMuted: false, accessibilityIdentifier: "audioCheckOutputMeter")
                .listRowSeparator(.hidden)
            Text(viewModel.isMuted ? "Microphone mute: On" : "Microphone mute: Off")
                .accessibilityIdentifier("audioCheckMuteState")
            Text(LocalizedStringKey(viewModel.audioCheckStatusMessage))
                .font(AppTypography.footnote)
                .foregroundStyle(AppColorPalette.textSecondary)
                .accessibilityIdentifier("audioCheckStatusLabel")
            if viewModel.isUsingWatchAudio {
                Text("Watch is using audio. Stop it before starting a check on this device.")
            }
            Button(action: toggleAudioCheck) {
                if viewModel.audioCheckPhase.isInProgress {
                    Label("Stop Audio Check", systemImage: "stop.fill")
                } else {
                    Label("Record 5s and Play", systemImage: "record.circle.fill")
                }
            }
            .disabled(!viewModel.audioCheckPhase.isInProgress && !viewModel.canStartAudioCheck)
            .accessibilityValue(Text(LocalizedStringKey(viewModel.audioCheckPhase.rawValue)))
            .accessibilityIdentifier("audioCheckButton")
        } header: {
            Text("Audio Check").accessibilityIdentifier("audioCheckPanel")
        }
    }

    private func toggleAudioCheck() {
        if viewModel.audioCheckPhase.isInProgress { viewModel.cancelAudioCheck() } else { viewModel.startAudioCheck() }
    }

    private var statusColor: Color {
        switch viewModel.audioCheckPhase {
        case .idle, .preparing: AppColorPalette.neutral
        case .recording, .failed: AppColorPalette.danger
        case .playing: AppColorPalette.success
        case .completed: AppColorPalette.info
        }
    }
}

/// Whether a device token is stored, and the sheet that sets the Worker URL and the token.
struct AdvancedInternetConnectionPanel: View {
    let viewModel: IntercomViewModel
    @Binding var isEditing: Bool

    var body: some View {
        Section {
            Text(viewModel.hasInternetCredentials ? "Device token configured" : "Not configured")
                .accessibilityIdentifier("internetConfigurationStatus")
            Button("Configure Internet Connection") { isEditing = true }
                .accessibilityIdentifier("configureInternetConnection")
        } header: {
            Text("Internet Connection")
        } footer: {
            Text("Set the service address and connect with Apple, or enter a device token for testing.")
        }
    }
}

/// Worker URL, connecting with Apple, and a manual device token for testing.
struct AdvancedInternetConnectionEditor: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var workerURL = ""
    @State private var token = ""
    @State private var status = ""
    private enum Field: Hashable { case url, token }
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section {
                TextField("Worker URL", text: $workerURL, prompt: Text(verbatim: "https://example.workers.dev"))
                    .focused($focusedField, equals: .url)
                    .internetAddressInput()
                    .accessibilityIdentifier("internetWorkerURL")
            }
            InternetAppleSignInSection(viewModel: viewModel, workerURL: workerURL)
            Section {
                SecureField("Device access token", text: $token, prompt: Text(verbatim: "Paste the token"))
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
                if !status.isEmpty { Text(LocalizedStringKey(status)).font(.footnote) }
            } header: {
                Text("Manual Access Token")
            } footer: {
                Text("Use your service URL and device token. Saving ends the current call. Cloudflare account secrets stay on the server.")
            }
        }
        .onAppear {
            workerURL = viewModel.internetWorkerURL
            if viewModel.hasInternetCredentials { status = "A device token is configured." }
        }
    }
}
