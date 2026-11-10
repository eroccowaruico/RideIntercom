#if os(iOS)
import XCTest

@MainActor
final class DesignSystemEntryUITests: XCTestCase {
    func testSignInShowsBrandAndReasonAtAccessibilitySizeInBothOrientations() {
        continueAfterFailure = false
        for japanese in [false, true] {
            let app = launch(japanese: japanese, signedIn: false)
            addTeardownBlock { [weak self] in
                guard app.state == .runningForeground else { return }
                self?.attach(app, japanese ? "Japanese sign-in teardown" : "English sign-in teardown")
                XCUIDevice.shared.orientation = .portrait
                app.terminate()
            }
            let glyph = app.descendants(matching: .any)["signInBrandGlyph"].firstMatch
            let reason = app.staticTexts["signInReason"].firstMatch
            let button = app.buttons["signInWithAppleButton"].firstMatch
            XCTAssertTrue(glyph.waitForExistence(timeout: 5))
            XCTAssertTrue(reason.exists)
            XCTAssertTrue(button.exists)
            let expectedReason = japanese
                ? "招待した仲間だけが通話に入れるよう、あなたを確かめるためにサインインします。メールアドレスと本名は使いません。"
                : "Sign in to verify you so only invited people can join your calls. We do not use your email address or real name."
            XCTAssertEqual(reason.label, expectedReason)
            revealSignInButton(button, in: app)
            attach(app, japanese ? "Japanese sign-in portrait" : "English sign-in portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            XCTAssertTrue(glyph.exists && reason.exists && button.exists)
            XCTAssertEqual(reason.label, expectedReason)
            revealSignInButton(button, in: app)
            attach(app, japanese ? "Japanese sign-in landscape" : "English sign-in landscape")
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
    }

    func testSignedInPersonChoosesANameBeforeUsingTheApp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launchEnvironment["RIDEINTERCOM_NAME_PROMPT"] = "1"
        // The argument domain starts every run from the never-chosen default name.
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "-RideIntercom.localDisplayNameChosen", "NO", "-RideIntercom.localDisplayName", "You"]
        app.launch()
        addTeardownBlock { [weak self] in
            guard app.state == .runningForeground else { return }
            self?.attach(app, "Name choice teardown")
            app.terminate()
        }
        let prompt = app.descendants(matching: .any)["displayNameChoice"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let field = app.textFields["displayNameChoiceField"].firstMatch
        let save = app.buttons["displayNameChoiceSaveButton"].firstMatch
        XCTAssertTrue(field.exists && save.exists)
        XCTAssertEqual(save.label, "はじめる")
        XCTAssertFalse(save.isEnabled, "An empty name cannot be saved")
        XCTAssertGreaterThanOrEqual(save.frame.width, app.windows.firstMatch.frame.width - 2 * 16 - 1,
                                    "The primary action spans the content width: \(save.frame)")
        attach(app, "Name choice before typing")
        field.tap()
        field.typeText("ナオ")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 5))
        // The empty state's one action is a full primary button, at least the 44pt touch target.
        let invite = app.buttons["emptyUsersInviteButton"].firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(invite.frame.height, 44, "\(invite.frame)")
        XCTAssertGreaterThan(invite.frame.width, app.windows.firstMatch.frame.width / 2, "\(invite.frame)")
        attach(app, "Users empty state")
    }

    func testDeveloperWarningHasHeadingAndPreservesInternetEntry() {
        continueAfterFailure = false
        for japanese in [false, true] {
            let app = launch(japanese: japanese, signedIn: true)
            defer { attach(app, japanese ? "Japanese developer settings" : "English developer settings"); app.terminate() }
            let tab = app.tabBars.buttons[japanese ? "設定" : "Settings"].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 8)); tab.tap()
            let form = app.collectionViews.firstMatch
            XCTAssertTrue(form.waitForExistence(timeout: 5))
            let link = app.buttons["moreSettingsLink"].firstMatch
            for _ in 0..<15 where !link.isHittable { form.swipeUp() }
            XCTAssertTrue(link.isHittable); link.tap()
            let heading = app.staticTexts["advancedSettingsWarningTitle"].firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 3))
            XCTAssertEqual(heading.label, japanese ? "通常は変更しないでください" : "Do not normally change these settings")
            XCTAssertTrue(app.staticTexts["advancedSettingsWarning"].exists)
            let configure = app.buttons["configureInternetConnection"].firstMatch
            let moreForm = app.collectionViews.firstMatch
            for _ in 0..<12 where !configure.isHittable { moreForm.swipeUp() }
            XCTAssertTrue(configure.isHittable)
        }
    }

    private func revealSignInButton(_ button: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 3))
        for _ in 0..<10 where !button.isHittable || !app.frame.contains(button.frame) { scroll.swipeUp() }
        XCTAssertTrue(button.isHittable, button.debugDescription)
        XCTAssertTrue(app.frame.contains(button.frame), button.debugDescription)
    }

    private func launch(japanese: Bool, signedIn: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = signedIn ? "signed-in" : "signed-out"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = name; screen.lifetime = .keepAlways; add(screen)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}
#endif
