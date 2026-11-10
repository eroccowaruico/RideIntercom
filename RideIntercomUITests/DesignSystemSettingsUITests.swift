#if os(iOS)
import XCTest

@MainActor
final class DesignSystemSettingsUITests: XCTestCase {
    /// Standard shows the name and Edit on one row; the sheet opens with the current name,
    /// shows "e.g. Nao" when emptied, and keeps Done off until a name is there.
    func testStandardDisplayNameEditsInItsOwnSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launch()
        defer { app.terminate() }
        let settings = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 8)); settings.tap()
        let row = app.buttons["localDisplayNameRow"].firstMatch
        reveal(row, in: app)
        XCTAssertFalse(app.textFields["localDisplayNameField"].exists, "No inline field on the Settings page")
        let current = row.label
        row.tap()
        let field = app.textFields["localDisplayNameField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(current.contains(field.value as? String ?? "-"), "Opens with the current name: \(current)")
        let done = app.buttons["saveLocalDisplayNameButton"].firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count))
        XCTAssertEqual(field.placeholderValue, "e.g. Nao")
        XCTAssertFalse(done.isEnabled, "Done stays off while the name is empty")
        field.typeText("Snow Cat")
        XCTAssertTrue(done.isEnabled)
        done.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
        XCTAssertTrue(row.label.contains("Snow Cat"), row.label)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Standard display name row"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testStandardInternetSetupRemainsReachableInMoreSettings() {
        continueAfterFailure = false
        for japanese in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)",
                                   "-AppleLocale", japanese ? "ja_JP" : "en_US"]
            app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
            app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
            app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
            app.launch()
            let settings = app.tabBars.buttons[japanese ? "設定" : "Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 8)); settings.tap()
            let more = app.buttons["moreSettingsLink"].firstMatch
            let rootForm = app.collectionViews.firstMatch
            XCTAssertTrue(rootForm.waitForExistence(timeout: 5))
            let lower = rootForm.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let upper = rootForm.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            for _ in 0..<20 {
                XCTAssertFalse(app.buttons["configureInternetConnection"].exists,
                               "Internet setup belongs inside More Settings")
                if more.isHittable { break }
                lower.press(forDuration: 0.05, thenDragTo: upper)
            }
            XCTAssertTrue(more.isHittable)
            more.tap()
            let warning = app.staticTexts["advancedSettingsWarning"].firstMatch
            XCTAssertTrue(warning.waitForExistence(timeout: 3))
            XCTAssertEqual(warning.label, japanese
                ? "ここの設定を変えると、音声や接続が正しく動かなくなることがあります。初期値以外の組み合わせはテストしていません。"
                : "Changing these settings can affect audio and connections. Combinations other than the defaults have not been tested.")
            let configure = app.buttons["configureInternetConnection"].firstMatch
            reveal(configure, in: app)
            configure.tap()
            let address = app.textFields["internetWorkerURL"].firstMatch
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["prepareInternetAppleSignIn"].exists)
            app.buttons["closeInternetConnection"].tap()
            XCTAssertTrue(configure.waitForExistence(timeout: 3))
            configure.tap()
            XCTAssertTrue(address.waitForExistence(timeout: 3))
            app.buttons["closeInternetConnection"].tap()
            reveal(warning, in: app)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = japanese ? "Japanese More Settings" : "English More Settings"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let lower = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let upper = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        for _ in 0..<20 where !element.isHittable { lower.press(forDuration: 0.05, thenDragTo: upper) }
        for _ in 0..<20 where !element.isHittable { upper.press(forDuration: 0.05, thenDragTo: lower) }
        XCTAssertTrue(element.waitForExistence(timeout: 3), element.debugDescription)
        XCTAssertTrue(element.isHittable, element.debugDescription)
    }
}
#endif
