import SwiftUI
import RTC

struct CallEntryView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab

    var body: some View {
        Group {
            if viewModel.selectedGroup != nil {
                CallView(viewModel: viewModel)
                    .navigationTitle(viewModel.selectedCallTitle)
            }
        }
        .safeAreaInset(edge: .top) {
            if let message = viewModel.groupErrorMessage,
               viewModel.selectedGroup != nil || message != viewModel.groupStorageNotice {
                Label(LocalizedStringKey(message), systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.regularMaterial)
                    .accessibilityIdentifier("groupErrorLabel")
            }
        }
    }
}
