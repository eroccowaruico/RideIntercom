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
                    .navigationTitle(viewModel.selectedGroup?.name ?? "Call")
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
            if let message = viewModel.groupErrorMessage {
                Label(message, systemImage: "key.horizontal")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.regularMaterial)
                    .accessibilityIdentifier("groupErrorLabel")
            }
        }
    }
}
