import SwiftUI
import RTC

struct CallEntryView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab

    var body: some View {
        Group {
            if viewModel.selectedGroup != nil {
                // The call's own content starts with the error, as an opaque card.
                CallView(viewModel: viewModel)
                    .navigationTitle(viewModel.selectedCallTitle)
            } else if let message = viewModel.groupErrorMessage, message != viewModel.groupStorageNotice {
                ScrollView { AdvancedCallErrorCard(message: message).padding(AppSpacing.screen) }
                    .screenBackground(AppColorPalette.listScreenBackground)
            }
        }
    }
}

/// An error or notice is content: an opaque card in the scroll, never a Material band over it.
struct AdvancedCallErrorCard: View {
    let message: String

    var body: some View {
        Label(LocalizedStringKey(message), systemImage: "exclamationmark.circle")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCallCardStyle()
            .accessibilityIdentifier("groupErrorLabel")
    }
}
