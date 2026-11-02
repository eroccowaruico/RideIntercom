import SwiftUI
#if os(iOS)
import UIKit
#endif

struct CallNotificationSettingsSection: View {
    let notifications: CallNotifications
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            HStack {
                Toggle("Receive Call Requests", isOn: Binding(
                    get: { notifications.isEnabled },
                    set: { enabled in
                        Task { if enabled { await notifications.enable() } else { await notifications.disable() } }
                    }
                ))
                .disabled((!notifications.canRegisterNotifications && !notifications.isEnabled) || notifications.isBusy)
                .accessibilityIdentifier("receiveCallNotificationsToggle")
                if notifications.isBusy { ProgressView() }
            }
            if notifications.authorizationDenied && notifications.canRegisterNotifications {
                Button("Open Settings") { openNotificationSettings() }
                    .accessibilityIdentifier("openNotificationSettings")
            } else if notifications.canRegisterNotifications && notifications.isEnabled && !notifications.receivesNotifications && notifications.message != nil {
                Button("Try Again") { Task { await notifications.enable() } }
                    .disabled(notifications.isBusy)
                    .accessibilityIdentifier("retryCallNotifications")
            }
        } header: {
            Text("Call Notifications")
        } footer: {
            if !notifications.isBusy {
                Text(status).accessibilityIdentifier("callNotificationsStatus")
            }
        }
        .task { await notifications.refresh() }
    }

    private var status: LocalizedStringKey {
        if !notifications.canRegisterNotifications { return "Internet connection is required to receive call requests." }
        if notifications.authorizationDenied { return "Notifications are not allowed in system settings." }
        if !notifications.isEnabled { return "Turn this on to receive call requests on this device." }
        if notifications.receivesNotifications { return "Call requests do not connect automatically." }
        if notifications.message != nil { return "Could not enable call requests. Try again." }
        return "Setting up call requests."
    }

    private func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { openURL(url) }
        #endif
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
