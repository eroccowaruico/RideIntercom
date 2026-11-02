#if os(iOS)
import XCTest

@MainActor
final class DesignSystemNotificationUITests: XCTestCase {
    func testCallNotificationUsesOneDisabledToggleWithoutInternet() {
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
            let toggle = app.switches["receiveCallNotificationsToggle"].firstMatch
            let lower = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let upper = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            for _ in 0..<12 where !toggle.isHittable { lower.press(forDuration: 0.05, thenDragTo: upper) }
            XCTAssertTrue(toggle.isHittable, app.debugDescription)
            XCTAssertEqual(toggle.label, japanese ? "呼び出しを受け取る" : "Receive Call Requests")
            XCTAssertEqual(toggle.value as? String, "0")
            XCTAssertFalse(toggle.isEnabled)
            let status = app.staticTexts["callNotificationsStatus"].firstMatch
            XCTAssertTrue(status.exists)
            for _ in 0..<4 where !status.isHittable { lower.press(forDuration: 0.05, thenDragTo: upper) }
            XCTAssertTrue(toggle.isHittable && status.isHittable, app.debugDescription)
            XCTAssertEqual(status.label, japanese ? "呼び出しを受け取るにはインターネット接続が必要です。" : "Internet connection is required to receive call requests.")
            XCTAssertFalse(app.buttons["checkCallNotifications"].exists)
            XCTAssertFalse(app.buttons["enableCallNotifications"].exists)
            XCTAssertFalse(app.buttons["disableCallNotifications"].exists)
        }
    }
}
#endif
