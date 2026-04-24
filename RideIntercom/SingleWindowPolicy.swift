import Foundation

#if os(macOS)
import AppKit

@MainActor
enum SingleWindowPolicy {
    private static let preferredContentSize = NSSize(width: 585, height: 844)
    private static var didApplyDefaultSize = false

    static func enforce() {
        NSWindow.allowsAutomaticWindowTabbing = false
        applyDefaultSizeIfNeeded()

        if !didApplyDefaultSize {
            DispatchQueue.main.async {
                applyDefaultSizeIfNeeded()
            }
        }
    }

    static func openMainWindowWhenNeeded(using opener: (() -> Void)?) {
        let hasVisibleTitledWindow = NSApplication.shared.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
        if !hasVisibleTitledWindow {
            opener?()
        }
    }

    private static func applyDefaultSizeIfNeeded() {
        guard let window = NSApplication.shared.windows.first(where: { $0.styleMask.contains(.titled) }) else {
            return
        }
        guard !didApplyDefaultSize else {
            return
        }

        didApplyDefaultSize = true
        window.setContentSize(preferredContentSize)
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
#endif
