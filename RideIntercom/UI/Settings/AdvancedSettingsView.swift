import SwiftUI

struct AdvancedSettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var isEditingInternet: Bool

    var body: some View {
        InterfaceModeSection(viewModel: viewModel)
        AccountSettingsPanel(viewModel: viewModel)
        StoreAccessSection(access: viewModel.storeAccess)
        LocalDisplayNameSection(viewModel: viewModel)
        CallDisconnectTimerSection(viewModel: viewModel)
        CallNotificationSettingsSection(notifications: viewModel.notifications)
        CallStatusDisplaySection(viewModel: viewModel)
        CommunicationPanel(viewModel: viewModel)
        InternetConnectionPanel(viewModel: viewModel, isEditing: $isEditingInternet)
        AudioSessionPanel(viewModel: viewModel)
        AudioIOPanel(viewModel: viewModel)
        VoiceActivityPanel(viewModel: viewModel)
        TransmitCodecPanel(viewModel: viewModel)
        AudioCheckPanel(viewModel: viewModel)
        ResetSettingsPanel(viewModel: viewModel)
    }
}
