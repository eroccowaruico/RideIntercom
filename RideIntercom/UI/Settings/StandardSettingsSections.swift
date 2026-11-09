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

/// One action, and below it only what the person needs: why it can't start, its progress, or its result.
struct StandardAudioCheckSection: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            Button(viewModel.audioCheckPhase.isInProgress ? "Stop Audio Check" : "Record 5s and Play") {
                if viewModel.audioCheckPhase.isInProgress { viewModel.cancelAudioCheck() } else { viewModel.startAudioCheck() }
            }
            .disabled(!viewModel.audioCheckPhase.isInProgress && !viewModel.canStartAudioCheck)
            .accessibilityValue(Text(LocalizedStringKey(viewModel.audioCheckPhase.rawValue)))
            .accessibilityIdentifier("audioCheckButton")
            if let note {
                HStack(spacing: AppSpacing.s) {
                    if viewModel.audioCheckPhase.isInProgress { ProgressView().controlSize(.small) }
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("audioCheckStatusLabel")
            }
        } header: {
            Text("Audio Check").accessibilityIdentifier("audioCheckPanel")
        }
    }

    /// Nothing while idle; the reason first when it can't start.
    private var note: LocalizedStringKey? {
        if viewModel.isUsingWatchAudio { return "Watch is using audio. Stop it before starting a check on this device." }
        if viewModel.hasAnyActiveGroupConnection { return "End your call before checking audio." }
        if viewModel.audioCheckPhase == .idle { return nil }
        return LocalizedStringKey(viewModel.audioCheckStatusMessage)
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
