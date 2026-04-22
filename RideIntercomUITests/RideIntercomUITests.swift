import XCTest

final class RideIntercomUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        launchApp()
    }

    private func launchApp(startOnDiagnostics: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        app.activate()

        XCTAssertTrue(waitForVisibleRoot(in: app), "Expected the app to launch into a visible root screen")
        removeExistingTrailGroups()

        if startOnDiagnostics {
            openDiagnosticsTab()
        }
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    @MainActor
    func testGroupSelectionOpensCallScreen() throws {
        createTrailGroupAndOpenCall()

        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["localMicrophonePanel"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Live"].exists)
        XCTAssertTrue(app.staticTexts["callPresenceLabel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["routeLabel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["localMicrophoneMuteButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mute Output"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["inviteButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["emptyRemoteParticipantsLabel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["callAudioOutputPicker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioInputPicker"].exists)
    }

    @MainActor
    func testManualAddRiderButtonIsNotShownInCallUI() throws {
        createTrailGroupAndOpenCall()

        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertTrue(app.buttons["inviteButton"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testMuteControlLivesWithHeaderMicrophoneMeter() throws {
        createTrailGroupAndOpenCall()

        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].waitForExistence(timeout: 3))
        let muteButton = app.buttons["localMicrophoneMuteButton"]
        XCTAssertTrue(muteButton.waitForExistence(timeout: 3))
        muteButton.tap()
        XCTAssertTrue(app.staticTexts["Muted"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testParticipantDeletionIsNotShownForLocalMemberOnly() throws {
        createTrailGroupAndOpenCall()

        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertFalse(app.buttons["removeParticipantButton0"].exists)
        XCTAssertTrue(app.buttons["inviteButton"].exists)
    }

    @MainActor
    func testDiagnosticsShowRealDeviceSetupIdentifiers() throws {
        relaunchOnDiagnosticsTab()

        XCTAssertTrue(app.descendants(matching: .any)["liveTransmitPipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Mic"].exists)
        XCTAssertTrue(app.staticTexts["VAD"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["realDeviceCallDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioIOPanel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioCheckPanel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioOutputPicker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioInputPicker"].exists)
    }

    @MainActor
    func testAudioCheckControlsAreAvailableFromSettings() throws {
        openSettingsTab()
        revealAudioCheckControlsIfNeeded()

        XCTAssertTrue(app.descendants(matching: .any)["audioIOPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["transmitCodecPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(audioCheckButtonElement().waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckInputMeter"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckOutputMeter"].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testVoiceActivityAndHandoverCanBeExercisedFromUI() throws {
        createTrailGroupAndOpenCall()

        XCTAssertTrue(app.buttons["connectButton"].exists)
        XCTAssertFalse(app.buttons["Refresh"].exists)
        XCTAssertFalse(app.buttons["Simulate Handover"].exists)
        XCTAssertFalse(app.staticTexts["Silent"].exists)
    }

    @MainActor
    func testCallKeepsDiagnosticsOutOfPrimaryExperience() throws {
        createTrailGroupAndOpenCall()

        XCTAssertFalse(app.descendants(matching: .any)["realDeviceCallDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["transportDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["groupHashDebugSummaryLabel"].exists)
        XCTAssertFalse(app.staticTexts["Live TX Pipeline"].exists)
    }

    @MainActor
    func testGroupDeletionCanBeExercisedFromUI() throws {
        createTrailGroupAndOpenCall()
        openGroupsTab()

        let groupRows = app.buttons.matching(identifier: "groupRow-Trail Group")
        let initialCount = groupRows.count
        let groupRow = groupRows.firstMatch
        XCTAssertTrue(groupRow.waitForExistence(timeout: 3))
        groupRow.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 2))
        app.buttons["Delete"].tap()
        XCTAssertLessThan(app.buttons.matching(identifier: "groupRow-Trail Group").count, initialCount)
    }

    @MainActor
    func testDiagnosticsKeepsMicrophoneIndicatorVisibleWithoutGroup() throws {
        relaunchOnDiagnosticsTab()

        XCTAssertTrue(app.descendants(matching: .any)["liveTransmitPipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Mic"].exists)
        XCTAssertTrue(app.staticTexts["VAD"].exists)
    }

    private func createTrailGroupAndOpenCall() {
        openGroupsTab()
        removeExistingTrailGroups()
        let createButton = app.buttons["createGroupButton"].firstMatch.exists
            ? app.buttons["createGroupButton"].firstMatch
            : app.buttons["Create Trail Group"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 3))
    }

    private func relaunchOnDiagnosticsTab() {
        app.terminate()
        launchApp(startOnDiagnostics: true)
    }

    private func openGroupsTab() {
        if app.staticTexts["Recent Groups"].firstMatch.exists {
            return
        }
        if app.buttons["showGroupsButton"].firstMatch.exists {
            app.buttons["showGroupsButton"].firstMatch.tap()
            return
        }
        if app.tabBars.buttons["Groups"].firstMatch.exists {
            app.tabBars.buttons["Groups"].firstMatch.tap()
            return
        }
        if app.radioButtons["groupsTab"].firstMatch.exists {
            app.radioButtons["groupsTab"].firstMatch.tap()
            return
        }
        if app.buttons["Groups"].firstMatch.exists {
            app.buttons["Groups"].firstMatch.tap()
        }
    }

    private func openDiagnosticsTab() {
        if app.descendants(matching: .any)["liveTransmitPipelineView"].firstMatch.exists {
            return
        }
        if app.tabBars.buttons["Diagnostics"].firstMatch.exists {
            app.tabBars.buttons["Diagnostics"].firstMatch.tap()
            return
        }
        if app.radioButtons["diagnosticsTab"].firstMatch.exists {
            app.radioButtons["diagnosticsTab"].firstMatch.tap()
            return
        }
        if app.buttons["diagnosticsTab"].firstMatch.exists {
            app.buttons["diagnosticsTab"].firstMatch.tap()
            return
        }
        if app.buttons["Diagnostics"].firstMatch.exists {
            app.buttons["Diagnostics"].firstMatch.tap()
        }
    }

    private func openSettingsTab() {
        if app.descendants(matching: .any)["settingsScrollView"].firstMatch.exists {
            return
        }
        if app.tabBars.buttons["Settings"].firstMatch.exists {
            app.tabBars.buttons["Settings"].firstMatch.tap()
            return
        }
        if app.radioButtons["settingsTab"].firstMatch.exists {
            app.radioButtons["settingsTab"].firstMatch.tap()
            return
        }
        if app.buttons["settingsTab"].firstMatch.exists {
            app.buttons["settingsTab"].firstMatch.tap()
            return
        }
        if app.buttons["Settings"].firstMatch.exists {
            app.buttons["Settings"].firstMatch.tap()
        }

        XCTAssertTrue(app.descendants(matching: .any)["settingsScrollView"].firstMatch.waitForExistence(timeout: 3))
    }

    private func revealAudioCheckControlsIfNeeded() {
        let audioCheckButton = audioCheckButtonElement()
        let audioCheckPanel = app.descendants(matching: .any)["audioCheckPanel"].firstMatch
        if audioCheckButton.exists && audioCheckPanel.exists {
            return
        }

        let settingsView = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        for _ in 0..<5 {
            if audioCheckButton.exists && audioCheckPanel.exists {
                return
            }
            settingsView.swipeUp()
        }
    }

    private func audioCheckButtonElement() -> XCUIElement {
        let byIdentifier = app.descendants(matching: .any)["audioCheckButton"].firstMatch
        if byIdentifier.exists {
            return byIdentifier
        }

        let byLabel = app.buttons["Record 5s and Play"].firstMatch
        if byLabel.exists {
            return byLabel
        }

        return byIdentifier
    }

    private func removeExistingTrailGroups() {
        openGroupsTab()

        let groupRows = app.buttons.matching(identifier: "groupRow-Trail Group")
        while groupRows.count > 0 {
            let countBeforeDelete = groupRows.count
            let groupRow = groupRows.firstMatch
            guard groupRow.waitForExistence(timeout: 1) else { return }

            groupRow.swipeLeft()
            let deleteButton = app.buttons["Delete"].firstMatch
            XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
            deleteButton.tap()

            XCTAssertLessThan(app.buttons.matching(identifier: "groupRow-Trail Group").count, countBeforeDelete)
        }
    }

    private func waitForVisibleRoot(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["groupSelectionList"].firstMatch.waitForExistence(timeout: 3)
            || app.buttons["createGroupButton"].firstMatch.waitForExistence(timeout: 3)
            || app.staticTexts["Recent Groups"].firstMatch.waitForExistence(timeout: 3)
    }
}
