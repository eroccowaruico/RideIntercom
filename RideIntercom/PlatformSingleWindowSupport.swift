import Foundation

#if canImport(AppKit)
import AppKit

@MainActor
enum SingleWindowPolicy {
    static let mainWindowID = "main"

    static func enforce() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    static func openMainWindowWhenNeeded(using opener: (() -> Void)?) {
        DispatchQueue.main.async {
            if visibleApplicationWindows().isEmpty {
                opener?()
            }
        }
    }

    private static func visibleApplicationWindows() -> [NSWindow] {
        NSApplication.shared.windows.filter { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
    }
}

@MainActor
final class RideIntercomApplicationDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleWindowPolicy.openMainWindowWhenNeeded(using: openMainWindow)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SingleWindowPolicy.openMainWindowWhenNeeded(using: openMainWindow)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            SingleWindowPolicy.openMainWindowWhenNeeded(using: openMainWindow)
        }

        return true
    }
}
#else
@MainActor
enum SingleWindowPolicy {
    static let mainWindowID = "main"

    static func enforce() {}
}
#endif
