import SwiftUI

struct CallNotificationSettingsSection: View {
    let notifications: CallNotifications
    var body: some View {
        Section("Call Notifications") {
            Text(LocalizedStringKey(notifications.receivesNotifications ? "Notifications are ready on this device." : "Notifications are not ready on this device."))
            Button("Check Notifications") { Task { await notifications.refresh() } }
                .disabled(notifications.isBusy).accessibilityIdentifier("checkCallNotifications")
            if notifications.isEnabled {
                Button("Disable Notifications") { Task { await notifications.disable() } }
                    .disabled(notifications.isBusy)
                    .accessibilityIdentifier("disableCallNotifications")
            } else {
                Button("Enable Notifications") { Task { await notifications.enable() } }
                    .disabled(!notifications.canRegisterNotifications || notifications.isBusy)
                    .accessibilityIdentifier("enableCallNotifications")
            }
            if let message = notifications.message { Text(LocalizedStringKey(message)).foregroundStyle(.secondary) }
            if !notifications.canRegisterNotifications { Text("Set up Internet calling to use notifications.").foregroundStyle(.secondary) }
        }
    }
}

struct CallNotificationContactSection: View {
    let viewModel: IntercomViewModel
    let userID: UUID
    var body: some View {
        Section {
            Toggle("Allow Call Requests", isOn: Binding(get: { viewModel.notifications.allowsIncoming(from: userID) },
                set: { allowed in Task { await viewModel.setCallNotificationsAllowed(allowed, for: userID) } }))
                .disabled(!viewModel.notifications.canUseNotifications || viewModel.notifications.isBusy)
                .accessibilityIdentifier("allowCallRequests-\(userID)")
            Button("Send Call Request") { Task { _ = await viewModel.notifications.send(to: userID) } }
                .disabled(!viewModel.notifications.canNotify(userID) || viewModel.notifications.isBusy)
                .accessibilityIdentifier("sendCallRequest-\(userID)")
            if viewModel.notifications.outgoing?.contactID == userID {
                Button("Cancel Call Request") { Task { await viewModel.notifications.cancelOutgoing() } }
                    .accessibilityIdentifier("cancelCallRequest-\(userID)")
            }
            if let message = viewModel.notifications.message { Text(LocalizedStringKey(message)).foregroundStyle(.secondary) }
        } header: { Text("Call Notifications") } footer: {
            Text("Allow this saved person to send call requests. Permission is shared when you connect one to one. Receiving also needs notifications enabled on this device. A request does not start a call automatically.")
        }
    }
}
