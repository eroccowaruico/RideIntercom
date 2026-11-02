import SwiftUI

struct StandardSettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var isEditingInternet: Bool

    var body: some View {
        InterfaceModeSection(viewModel: viewModel)
        AccountSettingsPanel(viewModel: viewModel)
        LocalDisplayNameSection(viewModel: viewModel)
        StoreAccessSection(access: viewModel.storeAccess)
        CallDisconnectTimerSection(viewModel: viewModel)
        CallNotificationSettingsSection(notifications: viewModel.notifications)
        CallStatusDisplaySection(viewModel: viewModel)
        InternetConnectionPanel(viewModel: viewModel, isEditing: $isEditingInternet)
        Section {
            NavigationLink("Communication") {
                Form { CommunicationPanel(viewModel: viewModel) }
                    .formStyle(.grouped)
                    .navigationTitle("Communication")
            }
            .accessibilityIdentifier("communicationSettingsLink")
        }
        AudioIOPanel(viewModel: viewModel)
        VoiceActivityPanel(viewModel: viewModel)
        AudioCheckPanel(viewModel: viewModel)
        Section {
            NavigationLink("More Audio and Connection Settings") {
                Form {
                    AudioSessionPanel(viewModel: viewModel)
                    TransmitCodecPanel(viewModel: viewModel)
                }
                .formStyle(.grouped)
                .navigationTitle("More Settings")
            }
            .accessibilityIdentifier("moreSettingsLink")
        }
        ResetSettingsPanel(viewModel: viewModel)
    }
}
