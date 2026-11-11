#if os(iOS)
import XCTest

@MainActor
final class DesignSystemNotificationUITests: XCTestCase {
    /// Notifications are set in the OS alone: the OS asks once at the first launch, and Settings has no
    /// notification section, switch or status.
    func testSettingsHaveNoNotificationSection() {
        continueAfterFailure = false
        for japanese in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)",
                                   "-AppleLocale", japanese ? "ja_JP" : "en_US"]
            app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
            app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
            app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
            app.launch()
            defer {
                let failureScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                failureScreen.name = japanese ? "Japanese notification final state" : "English notification final state"
                failureScreen.lifetime = .keepAlways
                add(failureScreen)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = japanese ? "Japanese notification accessibility hierarchy" : "English notification accessibility hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                app.terminate()
            }
            let settings = app.tabBars.buttons[japanese ? "設定" : "Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 8)); settings.tap()
            let form = app.collectionViews.firstMatch
            XCTAssertTrue(form.waitForExistence(timeout: 5))
            // Scroll through the whole form: no notification section, switch or status anywhere.
            let lower = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let upper = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let reset = app.buttons["moreSettingsLink"].firstMatch
            for _ in 0..<15 {
                for id in ["receiveCallNotificationsToggle", "callNotificationsStatus", "openNotificationSettings", "retryCallNotifications"] {
                    XCTAssertFalse(app.descendants(matching: .any)[id].exists, id)
                }
                XCTAssertFalse(app.staticTexts[japanese ? "呼び出しの通知" : "Call Notifications"].exists)
                if reset.isHittable { break }
                lower.press(forDuration: 0.05, thenDragTo: upper)
            }
            XCTAssertTrue(reset.isHittable, "Reached the end of the settings")
        }
    }
}
#endif
