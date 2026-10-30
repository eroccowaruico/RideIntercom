import SwiftUI
import RTC

struct CallEntryView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Group {
            if viewModel.selectedGroup == nil {
                GroupSelectionView(viewModel: viewModel)
                    .navigationTitle("Groups")
            } else {
                CallView(viewModel: viewModel)
                    .navigationTitle(viewModel.selectedCallTitle)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                viewModel.showGroupSelection()
                            } label: {
                                Label("Groups", systemImage: "person.3.fill")
                            }
                            .accessibilityIdentifier("showGroupsButton")
                        }
                    }
            }
        }
        .safeAreaInset(edge: .top) {
            if let message = viewModel.groupErrorMessage,
               viewModel.selectedGroup != nil || message != viewModel.groupStorageNotice {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.regularMaterial)
                    .accessibilityIdentifier("groupErrorLabel")
            }
        }
    }
}
