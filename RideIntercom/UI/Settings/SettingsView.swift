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
        .screenBackground(AppColorPalette.listScreenBackground)
        .readableScrollWidth()
        .accessibilityIdentifier("settingsScrollView")
        .sheet(isPresented: $isEditingInternet) {
            NavigationStack {
                Group {
                    if viewModel.interfaceMode == .standard {
                        StandardInternetConnectionEditor(viewModel: viewModel)
                    } else {
                        AdvancedInternetConnectionEditor(viewModel: viewModel)
                    }
                }
                .formStyle(.grouped)
                .screenBackground(AppColorPalette.listScreenBackground)
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

extension View {
    /// A web address: no autocorrection or capitals, and the URL keyboard.
    func internetAddressInput() -> some View {
        self.autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
    }
}
