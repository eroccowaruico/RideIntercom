import Foundation

extension AppCallOwner {
    /// Only the notification response callback calls this method, never arrival.
    @discardableResult
    func respondToCallNotification(_ tap: CallNotificationTap) async -> Bool {
        guard let model = viewModel, model.hasCurrentAccountAccess, model.accountSession === account else { return false }
        let accessID = model.accountAccessID
        guard let userID = await model.notifications.resolveTap(tap) else {
            if viewModel === model, model.hasCurrentAccountAccess {
                model.groupErrorMessage = "This call request is no longer available."
                callPresentationID = UUID()
            }
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
