import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The only authorization/APNs boundary. Unit and local automation never prompt.
@MainActor
enum NotificationSystem {
    static var permitsSystemAccess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["RIDEINTERCOM_LOCAL_TESTING"] != "1" && environment["XCTestConfigurationFilePath"] == nil && environment["XCTestBundlePath"] == nil
    }
    static func requestAuthorization() async throws -> Bool {
        guard permitsSystemAccess else { return false }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    static func authorizationGranted() async -> Bool {
        guard permitsSystemAccess else { return false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
    static func register() {
        guard permitsSystemAccess else { return }
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
    static func unregister() {
        guard permitsSystemAccess else { return }
        #if os(macOS)
        NSApplication.shared.unregisterForRemoteNotifications()
        #else
        UIApplication.shared.unregisterForRemoteNotifications()
        #endif
    }
    static var environment: String {
        switch Bundle.main.object(forInfoDictionaryKey: "RideIntercomAPNsEnvironment") as? String {
        case "development": return "sandbox"
        case "production": return "production"
        default:
            #if DEBUG
            return "sandbox"
            #else
            return "production"
            #endif
        }
    }
}
