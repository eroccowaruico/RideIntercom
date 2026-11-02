import SwiftUI
import RTC

struct StandardSettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var isEditingInternet: Bool

    var body: some View {
        AccountSettingsPanel(viewModel: viewModel)
        LocalDisplayNameSection(viewModel: viewModel)
        StoreAccessSection(access: viewModel.storeAccess)
        CallDisconnectTimerSection(viewModel: viewModel)
        CallNotificationSettingsSection(notifications: viewModel.notifications)
        CallStatusDisplaySection(viewModel: viewModel)
        Section {
            NavigationLink {
                Form { CommunicationPanel(viewModel: viewModel) }
                    .formStyle(.grouped)
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
        AudioIOPanel(viewModel: viewModel)
        VoiceActivityPanel(viewModel: viewModel)
        AudioCheckPanel(viewModel: viewModel)
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
                    InterfaceModeSection(viewModel: viewModel)
                    InternetConnectionPanel(viewModel: viewModel, isEditing: $isEditingInternet)
                    AudioSessionPanel(viewModel: viewModel)
                    TransmitCodecPanel(viewModel: viewModel)
                }
                .formStyle(.grouped)
                .navigationTitle("Advanced Settings for Developers")
            }
            .accessibilityIdentifier("moreSettingsLink")
        }
        ResetSettingsPanel(viewModel: viewModel)
    }

    @ViewBuilder private var routeNames: some View {
        if viewModel.isRTCTransportRouteEnabled(.multipeer) { Text("Local Network") }
        if viewModel.isRTCTransportRouteEnabled(.webRTC) { Text("Internet") }
    }
}
