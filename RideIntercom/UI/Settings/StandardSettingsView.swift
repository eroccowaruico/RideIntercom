import SwiftUI
import RTC

struct StandardSettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var isEditingInternet: Bool

    var body: some View {
        // Groups of the same purpose (you, connecting, routes, audio, advanced, reset). SwiftUI uses the larger
        // spacing of two neighbouring sections, so only the one-section groups (routes, advanced, reset) carry the
        // wider gap; that widens both of their edges and leaves the others compact.
        AccountSettingsPanel(viewModel: viewModel).groupedSettingsSpacing()
        StandardLocalDisplayNameSection(viewModel: viewModel).groupedSettingsSpacing()
        StoreAccessSection(access: viewModel.storeAccess).groupedSettingsSpacing()
        CallDisconnectTimerSection(viewModel: viewModel).groupedSettingsSpacing()
        CallNotificationSettingsSection(notifications: viewModel.notifications).groupedSettingsSpacing()
        CallStatusDisplaySection(viewModel: viewModel).groupedSettingsSpacing()
        Section {
            NavigationLink {
                Form { CommunicationPanel(viewModel: viewModel) }
                    .formStyle(.grouped)
                    .screenBackground(AppColorPalette.listScreenBackground)
                    .navigationTitle("Communication")
            } label: {
                LabeledContent("Communication") {
                    ViewThatFits(in: .horizontal) {
                        HStack { routeNames }
                        VStack(alignment: .trailing) { routeNames }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("communicationSettingsLink")
        }
        .groupedSettingsSpacing(separatesGroup: true)
        AudioIOPanel(viewModel: viewModel).groupedSettingsSpacing()
        VoiceActivityPanel(viewModel: viewModel).groupedSettingsSpacing()
        StandardAudioCheckSection(viewModel: viewModel).groupedSettingsSpacing()
        Section {
            NavigationLink("Advanced Settings for Developers") {
                Form {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: AppSpacing.s) {
                                Text("Do not normally change these settings")
                                    .font(.headline)
                                    .accessibilityIdentifier("advancedSettingsWarningTitle")
                                Text("Changing these settings can affect audio and connections. Combinations other than the defaults have not been tested.")
                                    .accessibilityIdentifier("advancedSettingsWarning")
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppColorPalette.warning)
                        }
                    }
                    StandardInterfaceModeSection(viewModel: viewModel)
                    // Display and Internet only; audio session and codec stay in Advanced Settings.
                    StandardInternetConnectionSection(viewModel: viewModel, isEditing: $isEditingInternet)
                }
                .formStyle(.grouped)
                .screenBackground(AppColorPalette.listScreenBackground)
                .navigationTitle("Advanced Settings for Developers")
            }
            .accessibilityIdentifier("moreSettingsLink")
        }
        .groupedSettingsSpacing(separatesGroup: true)
        ResetSettingsPanel(viewModel: viewModel).groupedSettingsSpacing(separatesGroup: true)
    }

    @ViewBuilder private var routeNames: some View {
        if viewModel.isRTCTransportRouteEnabled(.multipeer) { Text("Local Network") }
        if viewModel.isRTCTransportRouteEnabled(.webRTC) { Text("Internet") }
    }
}

private extension View {
    /// Compact between sections of one purpose; a visibly wider gap around a one-section group
    /// (the design sample adds a separator gap between groups).
    @ViewBuilder func groupedSettingsSpacing(separatesGroup: Bool = false) -> some View {
        #if os(iOS)
        listSectionSpacing(separatesGroup ? .custom(36) : .compact)
        #else
        self
        #endif
    }
}
