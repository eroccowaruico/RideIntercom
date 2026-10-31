import XCTest

final class StandardInterfaceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate(); app = nil }

    @MainActor
    func testStandardLayoutKeepsCallAcrossAdvancedSwitchAndPersistsChoice() throws {
        launch()
        XCTAssertFalse(app.tabBars.buttons["Diagnostics"].exists)
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + "Standard UI " + UUID().uuidString.prefix(6))
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        let mute = app.switches["standardMuteToggle"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 3))
        mute.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["standardMicrophoneStatus"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["standardMicrophoneStatus"].label, "Microphone muted")
        tab("Settings", id: "settingsTab")
        assertPurchasesUnavailable("Not Available Yet")
        selectLayout("Advanced")
        XCTAssertTrue(app.tabBars.buttons["Diagnostics"].exists || app.buttons["diagnosticsTab"].exists)
        tab("Call", id: "callTab")
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["localMicrophoneStateLabel"].label, "Muted")
        tab("Settings", id: "settingsTab")
        selectLayout("Standard")
        tab("Call", id: "callTab")
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["standardMicrophoneStatus"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["standardMicrophoneStatus"].label, "Microphone muted")
        XCTAssertTrue(app.staticTexts["standardSpeakerVolumeLabel"].exists)
        XCTAssertEqual(app.staticTexts["standardSpeakerVolumeLabel"].label, "Speaker Volume")
        screenshot("Standard call after switching layouts")
        app.buttons["standardEndCallButton"].tap()
        XCTAssertTrue(app.buttons["standardConnectButton"].waitForExistence(timeout: 3))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "RIDEINTERCOM_INTERFACE_FIXTURE")
        app.launch(); app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Diagnostics"].exists)
    }

    @MainActor
    func testStandardJapaneseNavigationAndUnconfiguredPurchases() {
        launch(japanese: true)
        XCTAssertTrue(app.staticTexts["通話を始める"].waitForExistence(timeout: 3))
        tab("ユーザー", id: "usersTab")
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
        tab("グループ", id: "groupsTab")
        XCTAssertTrue(app.buttons["standardCreateGroupButton"].waitForExistence(timeout: 3))
        screenshot("Japanese groups")
        tab("設定", id: "settingsTab")
        assertPurchasesUnavailable("まだ利用できません")
        XCTAssertTrue(app.staticTexts["購入はまだ利用できません。"].exists)
        screenshot("Japanese settings and unavailable purchases")
    }

    @MainActor
    func testStandardInternetSetupKeepsManualCredentialsInAdvanced() {
        launch()
        tab("Settings", id: "settingsTab")
        openInternetSettings()
        XCTAssertTrue(app.textFields["internetWorkerURL"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["internetWorkerURL"].placeholderValue, "Service Address")
        XCTAssertFalse(app.secureTextFields["internetDeviceToken"].exists)
        XCTAssertFalse(app.buttons["saveInternetConnection"].exists)
        XCTAssertTrue(app.buttons["prepareInternetAppleSignIn"].exists)
        app.buttons["closeInternetConnection"].tap()
        selectLayout("Advanced")
        openInternetSettings()
        XCTAssertTrue(app.secureTextFields["internetDeviceToken"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["internetWorkerURL"].placeholderValue, "Worker URL")
        XCTAssertTrue(app.buttons["saveInternetConnection"].exists)
    }

    @MainActor private func openInternetSettings() {
        let button = app.buttons["configureInternetConnection"].firstMatch
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 3)); button.tap()
    }

    @MainActor
    func testJapaneseInternetRetryShowsDelayAndKeepsAccount() {
        launch(japanese: true, throttled: true)
        tab("設定", id: "settingsTab")
        openInternetSettings()
        let address = app.textFields["internetWorkerURL"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeText("https://account.test")
        let prepare = app.buttons["prepareInternetAppleSignIn"]
        XCTAssertEqual(prepare.label, "インターネット通話を設定")
        prepare.tap()
        let status = app.staticTexts["internetAppleSignInStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("ログインの試行が多すぎます。60秒待ってから"))
        XCTAssertTrue(status.label.contains("「インターネット通話を設定」を選び直してください。"))
        XCTAssertFalse(app.buttons["internetAppleSignInButton"].isEnabled)
        prepare.tap()
        XCTAssertTrue(status.label.contains("秒待ってから"))
        screenshot("Japanese Internet retry instruction")
        app.buttons["closeInternetConnection"].tap()
        let signOut = app.buttons["signOutButton"]
        for _ in 0..<6 where !signOut.exists { app.swipeDown() }
        XCTAssertTrue(signOut.exists)
        XCTAssertFalse(app.otherElements["appleSignInScreen"].exists)
    }

    @MainActor private func launch(japanese: Bool = false, throttled: Bool = false) {
        app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        if throttled { app.launchEnvironment["RIDEINTERCOM_INTERNET_ACCOUNT_FIXTURE"] = "throttled" }
        app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"]
        app.launch(); app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor private func tab(_ title: String, id: String) {
        let identified = app.buttons[id].firstMatch
        if identified.exists { identified.tap() }
        else if app.radioButtons[id].exists { app.radioButtons[id].tap() }
        else {
            let button = app.tabBars.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3)); button.tap()
        }
    }

    @MainActor private func selectLayout(_ title: String) {
        let picker = app.descendants(matching: .any)["interfaceModePicker"].firstMatch
        for _ in 0..<6 where !picker.isHittable { app.swipeDown() }
        XCTAssertTrue(picker.waitForExistence(timeout: 3)); picker.tap()
        let choice = app.buttons[title].firstMatch
        if choice.exists { choice.tap() } else { app.menuItems[title].tap() }
    }

    @MainActor private func assertPurchasesUnavailable(_ title: String) {
        let status = app.descendants(matching: .any)["purchaseStatus"].firstMatch
        for _ in 0..<5 where !status.exists { app.swipeUp() }
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains(title) || (status.value as? String)?.contains(title) == true || status.staticTexts[title].exists, status.debugDescription)
        XCTAssertFalse(app.buttons["restorePurchases"].exists)
    }

    @MainActor private func screenshot(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
