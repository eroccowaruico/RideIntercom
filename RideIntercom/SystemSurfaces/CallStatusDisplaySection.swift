import SwiftUI

private struct CallLiveActivityPresenterKey: EnvironmentKey {
    static let defaultValue: CallLiveActivityPresenter? = nil
}
extension EnvironmentValues {
    var callLiveActivityPresenter: CallLiveActivityPresenter? {
        get { self[CallLiveActivityPresenterKey.self] }
        set { self[CallLiveActivityPresenterKey.self] = newValue }
    }
}

struct CallStatusDisplaySection: View {
    @Bindable var viewModel: IntercomViewModel
    @Environment(\.callLiveActivityPresenter) private var presenter
    var body: some View {
        Section {
            #if os(macOS)
            Toggle("Show call status in the menu bar", isOn: Binding(
                get: { viewModel.menuBarEnabled }, set: viewModel.setMenuBarEnabled))
                .accessibilityIdentifier("menuBarToggle")
            #else
            Toggle("Show call status outside the app", isOn: Binding(
                get: { viewModel.liveActivityEnabled }, set: viewModel.setLiveActivityEnabled))
                .accessibilityIdentifier("liveActivityToggle")
            if let message = presenter?.message { Text(String(localized: .init(stringLiteral: message))).foregroundStyle(.secondary) }
            #endif
        } header: {
            Text("Call status display")
        } footer: {
            #if os(macOS)
            Text("Show this Mac’s call status and controls without names. Hiding the menu bar item does not end your call.")
            #else
            Text("Show call status on the Lock Screen and Dynamic Island without names. Turning this off or dismissing the display does not end your call.")
            #endif
        }
    }
}
