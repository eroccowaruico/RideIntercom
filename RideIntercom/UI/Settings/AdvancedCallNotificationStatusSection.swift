import SwiftUI

/// Advanced shows `CallNotifications` as it is, read only. Notifications are set in the OS alone, so there is
/// no switch here; the values are checked again each time this appears.
struct AdvancedCallNotificationStatusSection: View {
    let notifications: CallNotifications

    var body: some View {
        Section {
            value("authorizationDenied", notifications.authorizationDenied)
            value("receivesNotifications", notifications.receivesNotifications)
            value("isBusy", notifications.isBusy)
            value("removalPending", notifications.removalPending)
            LabeledContent {
                Text(verbatim: notifications.message ?? "nil").textSelection(.enabled)
            } label: { Text(verbatim: "message") }
        } header: {
            Text("Call Notifications")
        }
        .accessibilityIdentifier("advancedCallNotificationStatus")
        .task { await notifications.refresh() }
    }

    private func value(_ name: String, _ value: Bool) -> some View {
        LabeledContent { Text(verbatim: String(value)).monospaced() } label: { Text(verbatim: name) }
    }
}
