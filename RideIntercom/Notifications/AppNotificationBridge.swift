import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Native callbacks route to the current account owner; arrival never starts a call.
@MainActor
final class AppNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    private weak var owner: AppCallOwner?
    func bind(to owner: AppCallOwner) {
        self.owner = owner
        if NotificationSystem.permitsSystemAccess {
            UNUserNotificationCenter.current().delegate = self
            #if os(iOS)
            UNUserNotificationCenter.current().setNotificationCategories([NotificationSystem.callRequestCategory])
            #endif
        }
    }
    func receivedDeviceToken(_ token: Data) {
        guard let model = owner?.viewModel, model.hasCurrentAccountAccess, let topic = Bundle.main.bundleIdentifier else { return }
        Task { await model.notifications.receivedDeviceToken(token, environment: NotificationSystem.environment, topic: topic) }
    }
    func registrationFailed() { owner?.viewModel?.notifications.registrationFailed() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let tap = CallNotificationTap(payload: response.notification.request.content.userInfo) else { return }
        _ = await respond(to: tap, actionIdentifier: response.actionIdentifier,
                          categoryIdentifier: response.notification.request.content.categoryIdentifier)
    }
    @discardableResult
    func respond(to tap: CallNotificationTap, actionIdentifier: String, categoryIdentifier: String) async -> Bool {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier
                || (actionIdentifier == NotificationSystem.respondOnPhoneActionIdentifier
                    && categoryIdentifier == NotificationSystem.callRequestCategoryIdentifier) else { return false }
        return await owner?.respondToCallNotification(tap) ?? false
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let tap = CallNotificationTap(payload: notification.request.content.userInfo) else { return [] }
        return await shouldPresent(tap) ? [.banner, .sound] : []
    }
    private func shouldPresent(_ tap: CallNotificationTap) -> Bool {
        guard let owner, let model = owner.viewModel, model.accountSession === owner.account,
              model.hasCurrentAccountAccess else { return false }
        return model.notifications.canReceive(tap)
    }
}

#if os(macOS)
extension RideIntercomApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) { notificationBridge?.receivedDeviceToken(token) }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) { notificationBridge?.registrationFailed() }
}
#else
@MainActor
final class RideIntercomApplicationDelegate: NSObject, UIApplicationDelegate {
    var notificationBridge: AppNotificationBridge?
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) { notificationBridge?.receivedDeviceToken(token) }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) { notificationBridge?.registrationFailed() }
}
#endif
