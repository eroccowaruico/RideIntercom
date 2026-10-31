import Foundation
import Observation

/// The app and system actions share the same account and call model.
@MainActor @Observable
final class AppCallOwner {
    let account: AppleAccountSession
    var viewModel: IntercomViewModel?
    var callPresentationID: UUID?

    init(account: AppleAccountSession, viewModel: IntercomViewModel?) {
        self.account = account
        self.viewModel = viewModel
    }
}
