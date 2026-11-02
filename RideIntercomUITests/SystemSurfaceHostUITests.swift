#if os(iOS)
import XCTest

@MainActor
final class SystemSurfaceHostUITests: XCTestCase {
    func testSelectedCallWidgetCanBeAddedFromHomeScreen() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForExistence(timeout: 8))
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        addTeardownBlock { [self] in
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Widget OS host full screen"; screen.lifetime = .keepAlways; add(screen)
            let tree = XCTAttachment(string: home.debugDescription)
            tree.name = "Widget OS host accessibility"; tree.lifetime = .keepAlways; add(tree)
            // Restore this test-owned simulator home layout.
            XCUIDevice.shared.press(.home)
            let widget = home.icons["RideCom"].firstMatch
            if widget.exists {
                widget.press(forDuration: 1.2)
                let appIcon = home.buttons["アプリアイコン"].firstMatch
                if appIcon.waitForExistence(timeout: 3) { appIcon.tap() }
                else { XCUIDevice.shared.press(.home) }
            }
            app.terminate()
        }
        let icon = home.icons["RideCom"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        icon.press(forDuration: 1.2)
        let small = home.buttons["小型のウィジェット"].firstMatch
        XCTAssertTrue(small.waitForExistence(timeout: 5))
        small.tap()
        // Dismiss the context menu without Home, which resets the selected page.
        if home.buttons["ホーム画面を編集"].firstMatch.exists {
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)).tap()
        }
        let guidance = home.staticTexts["長押しして接続先を設定"].firstMatch
        XCTAssertTrue(guidance.waitForExistence(timeout: 15))
        let choose = home.buttons["接続先を選ぶ"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5), home.debugDescription)
        XCTAssertTrue(choose.isHittable)
        let widgetScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        widgetScreen.name = "Selected call widget before opening app"
        widgetScreen.lifetime = .keepAlways; add(widgetScreen)
        choose.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForExistence(timeout: 5))
    }
}
#endif
