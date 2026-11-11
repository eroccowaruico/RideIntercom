import SwiftUI

struct AdvancedSettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var isEditingInternet: Bool

    var body: some View {
        AdvancedInterfaceModeSection(viewModel: viewModel)
        AccountSettingsPanel(viewModel: viewModel)
        StoreAccessSection(access: viewModel.storeAccess)
        LocalDisplayNameSection(viewModel: viewModel)
        CallDisconnectTimerSection(viewModel: viewModel)
        AdvancedCallNotificationStatusSection(notifications: viewModel.notifications)
        CallStatusDisplaySection(viewModel: viewModel)
        CommunicationPanel(viewModel: viewModel)
        AdvancedInternetConnectionPanel(viewModel: viewModel, isEditing: $isEditingInternet)
        AudioSessionPanel(viewModel: viewModel)
        AudioIOPanel(viewModel: viewModel)
        VoiceActivityPanel(viewModel: viewModel)
        TransmitCodecPanel(viewModel: viewModel)
        AdvancedAudioCheckPanel(viewModel: viewModel)
        ResetSettingsPanel(viewModel: viewModel)
    }
}
