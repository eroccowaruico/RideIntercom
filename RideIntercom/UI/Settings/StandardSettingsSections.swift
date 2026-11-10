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

/// The current name and Edit on one row; editing happens in its own sheet, as the design shows.
struct StandardLocalDisplayNameSection: View {
    let viewModel: IntercomViewModel
    @State private var isEditing = false

    var body: some View {
        Section {
            Button { isEditing = true } label: {
                LabeledContent {
                    Text("Edit")
                } label: {
                    Text(verbatim: viewModel.localMemberIdentity.displayName).foregroundStyle(.primary)
                }
            }
            // The name in the text color, "Edit" in the secondary color, as the design shows.
            .foregroundStyle(.primary)
            .accessibilityIdentifier("localDisplayNameRow")
            // On the row: a sheet on the Section itself does not present from inside a Form.
            .sheet(isPresented: $isEditing) { StandardDisplayNameEditor(viewModel: viewModel) }
        } header: {
            Text("Your Display Name")
        } footer: {
            Text("Choose the name you share with people in your groups. They can keep a different name for you on their own device.")
        }
    }
}

/// Opens with the current name; Done stays off while the field is empty.
private struct StandardDisplayNameEditor: View {
    let viewModel: IntercomViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name, prompt: Text("e.g. Nao"))
                        #if os(iOS)
                        .textContentType(.nickname)
                        #endif
                        .accessibilityIdentifier("localDisplayNameField")
                }
            }
            .formStyle(.grouped)
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle("Your Display Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { if viewModel.setLocalDisplayName(trimmed) { dismiss() } }
                        .disabled(!IntercomGroup.isValidName(trimmed))
                        .accessibilityIdentifier("saveLocalDisplayNameButton")
                }
            }
        }
        .onAppear { name = viewModel.localMemberIdentity.displayName }
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 420, minHeight: 200)
        #endif
    }
}
