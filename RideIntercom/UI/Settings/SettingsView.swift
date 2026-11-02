import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var isEditingInternet = false

    var body: some View {
        Form {
            if viewModel.interfaceMode == .standard {
                StandardSettingsView(viewModel: viewModel, isEditingInternet: $isEditingInternet)
            } else {
                AdvancedSettingsView(viewModel: viewModel, isEditingInternet: $isEditingInternet)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(viewModel.interfaceMode == .standard ? .hidden : .visible)
        .background {
            if viewModel.interfaceMode == .standard { AppColorPalette.standardScreenBackground }
        }
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
                TextField(LocalizedStringKey(viewModel.interfaceMode == .advanced ? "Worker URL" : "Service Address"), text: $workerURL)
                    .focused($focusedField, equals: .url)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("internetWorkerURL")
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            InternetAppleSignInSection(viewModel: viewModel, workerURL: workerURL)
            if viewModel.interfaceMode == .advanced {
                Section {
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
                    if !status.isEmpty { Text(LocalizedStringKey(status)).font(.footnote) }
                } header: { Label("Manual Access Token", systemImage: "globe") }
                footer: { Text("Use your service URL and device token. Saving ends the current call. Cloudflare account secrets stay on the server.") }
            }
        }
        .onAppear {
            workerURL = viewModel.internetWorkerURL
            if viewModel.hasInternetCredentials { status = "A device token is configured." }
        }
    }
}
