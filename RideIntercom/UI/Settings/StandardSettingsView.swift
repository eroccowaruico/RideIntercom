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
        InternetConnectionPanel(viewModel: viewModel, isEditing: $isEditingInternet)
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
            NavigationLink("More Audio and Connection Settings") {
                Form {
                    InterfaceModeSection(viewModel: viewModel)
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

    @ViewBuilder private var routeNames: some View {
        if viewModel.isRTCTransportRouteEnabled(.multipeer) { Text("Local Network") }
        if viewModel.isRTCTransportRouteEnabled(.webRTC) { Text("Internet") }
    }
}
