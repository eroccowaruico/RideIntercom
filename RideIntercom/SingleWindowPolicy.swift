import Foundation

#if canImport(AppKit)
import AppKit

@MainActor
enum SingleWindowPolicy {
    static let mainWindowID = "main"
    private static let preferredContentSize = NSSize(width: 585, height: 844)

    static func enforce() {
        NSWindow.allowsAutomaticWindowTabbing = false
        for window in NSApplication.shared.windows where window.styleMask.contains(.titled) {
            window.setContentSize(preferredContentSize)
            window.center()
        }

        DispatchQueue.main.async {
            for window in NSApplication.shared.windows where window.styleMask.contains(.titled) {
                window.setContentSize(preferredContentSize)
                window.center()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApplication.shared.windows where window.styleMask.contains(.titled) {
                window.setContentSize(preferredContentSize)
                window.center()
            }
        }
    }

    static func openMainWindowWhenNeeded(using opener: (() -> Void)?) {
        DispatchQueue.main.async {
            let hasVisibleTitledWindow = NSApplication.shared.windows.contains { window in
                window.isVisible && window.styleMask.contains(.titled)
            }
            if !hasVisibleTitledWindow {
                opener?()
            }
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
