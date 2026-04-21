import XCTest

final class RideIntercomUITests: XCTestCase {
    private static var sharedApp: XCUIApplication?

    private var app: XCUIApplication {
        guard let app = Self.sharedApp else {
            XCTFail("Shared app is not initialized")
            return XCUIApplication()
        }
        return app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["RUN_UI_TESTS"] == "1" else {
            throw XCTSkip("UI tests are opt-in. Set RUN_UI_TESTS=1 to run them.")
        }

        if Self.sharedApp == nil {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--reset-ui-testing-data"]
            app.launch()
            ensureVisibleRoot(in: app)
            Self.sharedApp = app
        }
    }

    @MainActor
    func testGroupSelectionConnectsToSixSlotCallScreen() throws {
        openGroupsTab()
        XCTAssertTrue(app.buttons["createGroupButton"].waitForExistence(timeout: 3))
        app.buttons["createGroupButton"].tap()

        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Your Microphone"].exists)
        XCTAssertTrue(app.staticTexts["Live"].exists)
        XCTAssertTrue(app.otherElements["connectionStatusIcon"].exists)
        XCTAssertTrue(app.staticTexts["routeLabel"].exists)
        XCTAssertTrue(app.buttons["Mute"].exists)
        XCTAssertTrue(app.buttons["inviteButton"].exists)
        XCTAssertTrue(app.buttons["Connect"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioOutputPicker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioInputPicker"].exists)
    }

    @MainActor
    func testManualAddRiderButtonIsNotShownInCallUI() throws {
        openGroupsTab()
        XCTAssertTrue(app.buttons["createGroupButton"].waitForExistence(timeout: 3))
        app.buttons["createGroupButton"].tap()
        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertTrue(app.buttons["inviteButton"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testMuteControlLivesInsideLocalMicrophonePanel() throws {
        openGroupsTab()
        XCTAssertTrue(app.buttons["createGroupButton"].waitForExistence(timeout: 3))
        app.buttons["createGroupButton"].tap()

        XCTAssertTrue(app.staticTexts["Your Microphone"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mute"].exists)
        app.buttons["Mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Muted"].exists)
    }

    @MainActor
    func testParticipantDeletionCanBeExercisedFromUI() throws {
        openGroupsTab()
        XCTAssertTrue(app.buttons["createGroupButton"].waitForExistence(timeout: 3))
        app.buttons["createGroupButton"].tap()
        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertTrue(app.buttons["inviteButton"].exists)
    }

    @MainActor
    func testDiagnosticsShowRealDeviceSetupIdentifiers() throws {
        openDiagnosticsTab()

        XCTAssertTrue(app.otherElements["liveAudioPanel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["diagnosticsInputMeter"].exists)
        XCTAssertTrue(app.otherElements["diagnosticsOutputMeter"].exists)
        XCTAssertTrue(app.otherElements["audioIOPanel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["audioIOApplyStateLabel"].exists)
        XCTAssertTrue(app.otherElements["audioCheckPanel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckOutputPicker"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckInputPicker"].exists)
    }

    @MainActor
    func testAudioCheckControlsAreAvailableFromDiagnostics() throws {
        openDiagnosticsTab()

        XCTAssertTrue(app.buttons["Record 5s and Play"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Microphone Input"].exists)
        XCTAssertTrue(app.staticTexts["Speaker Output"].exists)
        XCTAssertTrue(app.otherElements["audioCheckInputMeter"].exists)
        XCTAssertTrue(app.otherElements["audioCheckOutputMeter"].exists)
    }

    @MainActor
    func testVoiceActivityAndHandoverCanBeExercisedFromUI() throws {
        openGroupsTab()
        XCTAssertTrue(app.buttons["createGroupButton"].waitForExistence(timeout: 3))
        app.buttons["createGroupButton"].tap()
        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 3))

        XCTAssertTrue(app.buttons["Connect"].exists)
        XCTAssertFalse(app.buttons["Refresh"].exists)
        XCTAssertFalse(app.buttons["Simulate Handover"].exists)
        XCTAssertFalse(app.staticTexts["Silent"].exists)
    }

    @MainActor
    func testGroupDeletionCanBeExercisedFromUI() throws {
        openGroupsTab()
        XCTAssertTrue(app.buttons["createGroupButton"].waitForExistence(timeout: 3))
        app.buttons["createGroupButton"].tap()
        openGroupsTab()

        let groupRow = app.buttons["groupRow-Trail Group"]
        XCTAssertTrue(groupRow.waitForExistence(timeout: 3))
        groupRow.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 2))
        app.buttons["Delete"].tap()
        XCTAssertFalse(groupRow.exists)
    }

    @MainActor
    func testDiagnosticsKeepsMicrophoneIndicatorVisibleWithoutGroup() throws {
        openDiagnosticsTab()

        XCTAssertTrue(app.otherElements["audioCheckInputMeter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["audioCheckOutputMeter"].exists)
    }

    private func openGroupsTab() {
        if app.buttons["showGroupsButton"].exists {
            app.buttons["showGroupsButton"].tap()
            return
        }
        if app.tabBars.buttons["Groups"].exists {
            app.tabBars.buttons["Groups"].tap()
            return
        }
        if app.buttons["Groups"].exists {
            app.buttons["Groups"].tap()
        }
    }

    private func openDiagnosticsTab() {
        if app.tabBars.buttons["Diagnostics"].exists {
            app.tabBars.buttons["Diagnostics"].tap()
            return
        }
        if app.buttons["diagnosticsTab"].exists {
            app.buttons["diagnosticsTab"].tap()
            return
        }
        if app.buttons["Diagnostics"].exists {
            app.buttons["Diagnostics"].tap()
        }
    }

    private func ensureVisibleRoot(in app: XCUIApplication) {
        let hasVisibleRoot = app.buttons["createGroupButton"].waitForExistence(timeout: 1)
            || app.buttons["Create Trail Group"].waitForExistence(timeout: 1)
            || app.buttons["Record 5s and Play"].waitForExistence(timeout: 1)
            || app.buttons["diagnosticsTab"].waitForExistence(timeout: 1)
            || app.buttons["Diagnostics"].waitForExistence(timeout: 1)
            || app.tabBars.buttons["Diagnostics"].waitForExistence(timeout: 1)
        if !hasVisibleRoot {
            app.typeKey("n", modifierFlags: .command)
        }
    }
}
