import SwiftUI

/// 標準／詳細 side by side, in Advanced Settings for Developers.
struct StandardInterfaceModeSection: View {
    let viewModel: IntercomViewModel

    var body: some View {
        Section {
            Picker("App Layout", selection: Binding(get: { viewModel.interfaceMode }, set: viewModel.setInterfaceMode)) {
                Text("Standard").tag(InterfaceMode.standard)
                Text("Advanced").tag(InterfaceMode.advanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("interfaceModePicker")
        } header: {
            Text("App Layout")
        } footer: {
            Text("Advanced shows diagnostics and detailed settings (English only).")
        }
    }
}

/// One action; while it runs, the state word with the same voice indicator as a call, and one sentence below.
/// Device names, numbers and meters stay in Advanced.
struct StandardAudioCheckSection: View {
    @Bindable var viewModel: IntercomViewModel

    private var phase: AudioCheckPhase { viewModel.audioCheckPhase }

    var body: some View {
        Section {
            Button(phase.isInProgress ? "Stop Audio Check" : "Record 5s and Play") {
                if phase.isInProgress { viewModel.cancelAudioCheck() } else { viewModel.startAudioCheck() }
            }
            .disabled(!phase.isInProgress && !viewModel.canStartAudioCheck)
            .accessibilityValue(Text(LocalizedStringKey(phase.rawValue)))
            .accessibilityIdentifier("audioCheckButton")
            stateRow
        } header: {
            Text("Audio Check").accessibilityIdentifier("audioCheckPanel")
        } footer: {
            if let footer { Text(footer).accessibilityIdentifier("audioCheckFooter") }
        }
    }

    @ViewBuilder private var stateRow: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .preparing:
            row(Text("Preparing now")) { ProgressView().controlSize(.small) }
        case .recording:
            row(Text("Recording now")) {
                StandardVoiceIndicator(kind: .input, level: viewModel.diagnosticsInputLevel, label: Text("Your voice"))
            }
        case .playing:
            row(Text("Playing back now")) {
                StandardVoiceIndicator(kind: .output, level: viewModel.diagnosticsOutputLevel, label: Text("Output"))
            }
        case .completed:
            row(Text("Audio check finished")) { EmptyView() }
        case .failed:
            // The implementation's reason, as one sentence.
            row(Text(LocalizedStringKey(viewModel.audioCheckStatusMessage))) { EmptyView() }
        }
    }

    private func row(_ title: Text, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            title
            Spacer()
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("audioCheckStatusLabel")
    }

    /// Why it cannot start, or what to do in this state.
    private var footer: LocalizedStringKey? {
        switch phase {
        case .idle:
            if viewModel.isUsingWatchAudio { return "Watch is using audio. Stop it before starting a check on this device." }
            if viewModel.hasAnyActiveGroupConnection { return "End your call before checking audio." }
            return nil
        case .preparing, .failed: return nil
        case .recording: return "Speak now. Your recording plays back next."
        case .playing: return "If you can hear your recording, your microphone and speaker work."
        case .completed: return "If you couldn't hear it, check the volume and your audio device."
        }
    }
}

/// Whether Internet is set up, and the sheet with the service address and connecting with Apple.
struct StandardInternetConnectionSection: View {
    let viewModel: IntercomViewModel
    @Binding var isEditing: Bool

    var body: some View {
        Section {
            HStack {
                Text(viewModel.hasInternetCredentials ? "Set up" : "Not set up")
                Spacer()
                if viewModel.hasInternetCredentials {
                    Image(systemName: "checkmark").foregroundStyle(AppColorPalette.success).accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("internetConfigurationStatus")
            Button("Set Up Internet Connection") { isEditing = true }
                .accessibilityIdentifier("configureInternetConnection")
        } header: {
            Text("Internet Connection")
        }
    }
}

/// The service address and connecting with Apple; no device token.
struct StandardInternetConnectionEditor: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var address = ""

    var body: some View {
        Form {
            Section {
                TextField("Service Address", text: $address, prompt: Text("Address starting with https://"))
                    .internetAddressInput()
                    .accessibilityIdentifier("internetWorkerURL")
            }
            InternetAppleSignInSection(viewModel: viewModel, workerURL: address)
        }
        .onAppear { address = viewModel.internetWorkerURL }
    }
}
