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
            Toggle("Show call status outside the app", isOn: Binding(
                get: { viewModel.liveActivityEnabled }, set: viewModel.setLiveActivityEnabled))
                .accessibilityIdentifier("liveActivityToggle")
            if let message = presenter?.message { Text(String(localized: .init(stringLiteral: message))).foregroundStyle(.secondary) }
        } header: {
            Text("Call status display")
        } footer: {
            Text("Show call status on the Lock Screen and Dynamic Island without names. Turning this off or dismissing the display does not end your call.")
        }
    }
}
