import Foundation

extension AppCallOwner {
    /// Only the notification response callback calls this method, never arrival.
    @discardableResult
    func respondToCallNotification(_ tap: CallNotificationTap) async -> Bool {
        guard let model = viewModel, model.hasCurrentAccountAccess, model.accountSession === account else { return false }
        let accessID = model.accountAccessID
        guard let userID = await model.notifications.resolveTap(tap) else {
            // An old notice whose sender cannot be resolved opens your users, without an error.
            if viewModel === model, model.hasCurrentAccountAccess { usersPresentationID = UUID() }
            return false
        }
        guard viewModel === model, model.hasCurrentAccountAccess, model.accountAccessID == accessID else { return false }
        // In one place at a time: while connected elsewhere, the notice only opens the current call.
        if model.hasAnyActiveGroupConnection, !model.isActiveCall(.user(userID)) {
            model.showLiveCall()
            callPresentationID = UUID()
            return false
        }
        let started = model.startCall(to: .user(userID), accountAccessID: accessID, allowSwitchingCall: false)
        callPresentationID = UUID()
        return started
    }
}
