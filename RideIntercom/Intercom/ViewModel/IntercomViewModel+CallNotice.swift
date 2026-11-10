import Foundation

/// RideCom is used like an intercom or a web meeting: people join at the same time or arrange it by
/// other means. A call notification is only a courtesy, like being told the first person has joined
/// (see the product requirements). It is sent once and never followed up: no resend, no waiting
/// display, no withdrawal, no Decline.
extension IntercomViewModel {
    /// Each new one-to-one connection notifies the person once, when they take call requests from here.
    func noticeNewDirectCall(to userID: UUID) {
        guard notifications.canNotify(userID) else { return }
        Task { [notifications] in _ = await notifications.send(to: userID) }
    }
}
