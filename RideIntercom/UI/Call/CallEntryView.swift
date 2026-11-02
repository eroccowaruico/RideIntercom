import SwiftUI
import RTC

struct CallEntryView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab

    var body: some View {
        Group {
            if viewModel.selectedGroup == nil {
                List {
                    CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab)
                    StandardStorageSection(viewModel: viewModel)
                    Section {
                        ContentUnavailableView("Ready to Talk", systemImage: "phone", description: Text("Choose someone or a group to call."))
                        Button("Choose a User") { selectedTab = .users }
                            .accessibilityIdentifier("chooseUserButton")
                        Button("Choose a Group") { selectedTab = .groups }
                            .accessibilityIdentifier("chooseGroupButton")
                    }
                }
                .accessibilityIdentifier("advancedCallEmptyState")
                .navigationTitle("Call")
            } else {
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
