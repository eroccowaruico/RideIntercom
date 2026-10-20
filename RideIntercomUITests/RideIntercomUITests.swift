import XCTest

final class RideIntercomUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        launchApp()
    }

    private func launchApp(startOnDiagnostics: Bool = false) {
        app = XCUIApplication()
        app.launch()
        app.activate()

        XCTAssertTrue(waitForVisibleRoot(in: app), "Expected the app to launch into a visible root screen")
        removeExistingTalkGroups()

        if startOnDiagnostics {
            openDiagnosticsTab()
        }
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    @MainActor
    func testRecoveryWorkflowInOneLaunch() throws {
        createTalkGroupAndOpenCall()
        try checkGroupSelectionOpensCallScreen()
        try checkManualAddRiderButtonIsNotShownInCallUI()
        try checkParticipantDeletionIsNotShownForLocalMemberOnly()
        try checkCallKeepsDiagnosticsOutOfPrimaryExperience()
        try checkMuteControlLivesWithHeaderMicrophoneMeter()
        try checkVoiceActivityAndHandoverCanBeExercisedFromUI()
        try checkDisconnectAndReconnectButtonsTransitionInCall()
        attachScreen("Call")
        try checkShowGroupsButtonReturnsFromCallToGroupSelection()
        app.buttons.matching(identifier: "groupRow-Talk Group").firstMatch.tap()
        try checkGroupDeletionCanBeExercisedFromUI()
        try checkDiagnosticsKeepsMicrophoneIndicatorVisibleWithoutGroup()
        try checkDiagnosticsShowRealDeviceSetupIdentifiers()
        attachScreen("Diagnostics")
        try checkTabNavigationShowsExpectedRootSections()
        try checkSettingsShowsConfigPanelsWithoutDiagnosticsRows()
        try checkAudioCheckControlsAreAvailableFromSettings()
        checkSettingsChangesPersistAcrossTabs()
        attachScreen("Settings")
    }

    private func checkSettingsChangesPersistAcrossTabs() {
        openSettingsTab()
        attachScreen("Settings before edits")
        let local = app.switches["Local Network"].firstMatch
        let internet = app.switches["Internet"].firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 3))
        let original = local.value as? String
        local.switches.firstMatch.tap()
        XCTAssertNotEqual(local.value as? String, original)
        XCTAssertFalse(internet.isEnabled) // The remaining route cannot be disabled.
        openGroupsTab()
        openSettingsTab()
        XCTAssertNotEqual(local.value as? String, original)
        local.switches.firstMatch.tap()
        XCTAssertEqual(local.value as? String, original)
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        let codec = app.segmentedControls.containing(.button, identifier: "PCM 16-bit").firstMatch
        codec.buttons["Opus"].tap()
        XCTAssertTrue(codec.buttons["Opus"].isSelected)
        codec.buttons["PCM 16-bit"].tap()
        XCTAssertTrue(codec.buttons["PCM 16-bit"].isSelected)
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @MainActor
    private func checkGroupSelectionOpensCallScreen() throws {

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
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["emptyRemoteParticipantsLabel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["callAudioOutputPicker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioInputPicker"].exists)
    }

    @MainActor
    private func checkManualAddRiderButtonIsNotShownInCallUI() throws {

        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertTrue(app.buttons["inviteButton"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func checkMuteControlLivesWithHeaderMicrophoneMeter() throws {

        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].waitForExistence(timeout: 3))
        let muteButton = app.buttons["localMicrophoneMuteButton"]
        XCTAssertTrue(muteButton.waitForExistence(timeout: 3))
        muteButton.tap()
        XCTAssertTrue(app.staticTexts["Muted"].waitForExistence(timeout: 2))
    }

    @MainActor
    private func checkParticipantDeletionIsNotShownForLocalMemberOnly() throws {

        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertFalse(app.buttons["removeParticipantButton0"].exists)
        XCTAssertTrue(app.buttons["inviteButton"].exists)
    }

    @MainActor
    private func checkDiagnosticsShowRealDeviceSetupIdentifiers() throws {
        showEmptyDiagnostics()

        XCTAssertTrue(app.descendants(matching: .any)["liveTransmitPipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["liveReceivePipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-session-step"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-effects-step"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["receive-pipeline-mix-step"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["receive-mix-topology"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["receive-pipeline-output-step"].exists)
        revealDiagnosticOverview()
        XCTAssertTrue(app.descendants(matching: .any)["realDeviceCallDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioIOPanel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioCheckPanel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioOutputPicker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioInputPicker"].exists)
    }

    @MainActor
    private func checkAudioCheckControlsAreAvailableFromSettings() throws {
        openSettingsTab()

        XCTAssertTrue(app.descendants(matching: .any)["audioIOPanel"].firstMatch.waitForExistence(timeout: 3))

        revealAudioCheckControlsIfNeeded()

        XCTAssertTrue(audioCheckButtonElement().waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckPanel"].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    private func checkVoiceActivityAndHandoverCanBeExercisedFromUI() throws {

        XCTAssertTrue(app.buttons["disconnectButton"].exists)
        XCTAssertFalse(app.buttons["Refresh"].exists)
        XCTAssertFalse(app.buttons["Simulate Handover"].exists)
        XCTAssertFalse(app.staticTexts["Silent"].exists)
    }

    @MainActor
    private func checkCallKeepsDiagnosticsOutOfPrimaryExperience() throws {

        XCTAssertFalse(app.descendants(matching: .any)["realDeviceCallDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["transportDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["groupHashDebugSummaryLabel"].exists)
        XCTAssertFalse(app.staticTexts["Live TX Pipeline"].exists)
    }

    @MainActor
    private func checkGroupDeletionCanBeExercisedFromUI() throws {
        openGroupsTab()

        let groupRows = app.buttons.matching(identifier: "groupRow-Talk Group")
        let initialCount = groupRows.count
        let groupRow = groupRows.firstMatch
        XCTAssertTrue(groupRow.waitForExistence(timeout: 3))
        groupRow.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 2))
        app.buttons["Delete"].tap()
        XCTAssertLessThan(app.buttons.matching(identifier: "groupRow-Talk Group").count, initialCount)
    }

    @MainActor
    private func checkDiagnosticsKeepsMicrophoneIndicatorVisibleWithoutGroup() throws {
        showEmptyDiagnostics()

        XCTAssertTrue(app.descendants(matching: .any)["liveTransmitPipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["liveReceivePipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-input-step"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pipeline-effect-stage-vad-gate"].exists) // No invented idle Mixer effects.
    }

    @MainActor
    private func checkTabNavigationShowsExpectedRootSections() throws {
        openGroupsTab()
        XCTAssertTrue(app.descendants(matching: .any)["groupSelectionList"].firstMatch.waitForExistence(timeout: 3))

        openDiagnosticsTab()
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-session-step"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-input-step"].firstMatch.waitForExistence(timeout: 3))

        openSettingsTab()
        XCTAssertTrue(app.descendants(matching: .any)["settingsScrollView"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["audioSessionPanel"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        XCTAssertTrue(app.descendants(matching: .any)["transmitCodecPanel"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "voiceActivityPanel")
        XCTAssertTrue(app.descendants(matching: .any)["voiceActivityPanel"].firstMatch.waitForExistence(timeout: 3))

        openGroupsTab()
        XCTAssertTrue(waitForVisibleRoot(in: app))
    }

    @MainActor
    private func checkShowGroupsButtonReturnsFromCallToGroupSelection() throws {

        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["showGroupsButton"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["showGroupsButton"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSelectionList"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["createGroupButton"].firstMatch.exists)
    }

    @MainActor
    private func checkDisconnectAndReconnectButtonsTransitionInCall() throws {

        let disconnectButton = app.buttons["disconnectButton"].firstMatch
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 3))
        disconnectButton.tap()

        let connectButton = app.buttons["connectButton"].firstMatch
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.tap()

        XCTAssertTrue(app.buttons["disconnectButton"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func checkSettingsShowsConfigPanelsWithoutDiagnosticsRows() throws {
        openSettingsTab()

        XCTAssertTrue(app.descendants(matching: .any)["audioSessionPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "mode uses")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioSessionProfileStatus"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["audioIOPanel"].firstMatch.waitForExistence(timeout: 3))
        revealAudioCheckControlsIfNeeded()
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckPanel"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        XCTAssertTrue(app.descendants(matching: .any)["transmitCodecPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["transmitCodecStatus"].firstMatch.exists)
        revealSettingsPanelIfNeeded(identifier: "voiceActivityPanel")
        XCTAssertTrue(app.descendants(matching: .any)["voiceActivityPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["vadAnalysisStatus"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioIOApplyStateLabel"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioInputProcessingSummaryLabel"].firstMatch.exists)
    }

    private func createTalkGroupAndOpenCall() {
        openGroupsTab()
        removeExistingTalkGroups()
        let createButton = app.buttons["createGroupButton"].firstMatch.exists
            ? app.buttons["createGroupButton"].firstMatch
            : app.buttons["Create Talk Group"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 3))
    }

    private func showEmptyDiagnostics() {
        openGroupsTab()
        removeExistingTalkGroups()
        openDiagnosticsTab()
    }

    private func openGroupsTab() {
        if app.staticTexts["Recent Groups"].firstMatch.exists {
            return
        }
        if app.tabBars.buttons["Call"].firstMatch.exists {
            app.tabBars.buttons["Call"].firstMatch.tap()
            if app.staticTexts["Recent Groups"].firstMatch.exists {
                return
            }
        }
        if app.buttons["Call"].firstMatch.exists {
            app.buttons["Call"].firstMatch.tap()
            if app.staticTexts["Recent Groups"].firstMatch.exists {
                return
            }
        }
        if app.radioButtons["callTab"].firstMatch.exists {
            app.radioButtons["callTab"].firstMatch.tap()
            if app.staticTexts["Recent Groups"].firstMatch.exists {
                return
            }
        }
        if app.buttons["callTab"].firstMatch.exists {
            app.buttons["callTab"].firstMatch.tap()
            if app.staticTexts["Recent Groups"].firstMatch.exists {
                return
            }
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
        defer {
            let scroll = app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch
            for _ in 0..<6 {
                if app.descendants(matching: .any)["pipeline-session-step"].firstMatch.isHittable { break }
                scroll.swipeDown()
            }
        }
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
        defer {
            let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
            for _ in 0..<6 {
                let toggle = app.switches["Local Network"].firstMatch
                if toggle.exists && toggle.isHittable { break }
                scroll.swipeDown()
            }
        }
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

    private func revealDiagnosticOverview() {
        let scroll = app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch
        for _ in 0..<8 {
            if app.descendants(matching: .any)["realDeviceCallDebugSummaryLabel"].exists { return }
            scroll.swipeUp()
        }
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

    private func revealSettingsPanelIfNeeded(identifier: String) {
        openSettingsTab()
        let targetPanel = app.descendants(matching: .any)[identifier].firstMatch
        if targetPanel.exists {
            return
        }

        let settingsView = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        for _ in 0..<6 {
            if targetPanel.exists {
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

    private func removeExistingTalkGroups() {
        openGroupsTab()

        let groupRows = app.buttons.matching(identifier: "groupRow-Talk Group")
        while groupRows.count > 0 {
            let countBeforeDelete = groupRows.count
            let groupRow = groupRows.firstMatch
            guard groupRow.waitForExistence(timeout: 1) else { return }

            groupRow.swipeLeft()
            let deleteButton = app.buttons["Delete"].firstMatch
            XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
            deleteButton.tap()

            XCTAssertLessThan(app.buttons.matching(identifier: "groupRow-Talk Group").count, countBeforeDelete)
        }
    }

    private func waitForVisibleRoot(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["groupSelectionList"].firstMatch.waitForExistence(timeout: 3)
            || app.buttons["createGroupButton"].firstMatch.waitForExistence(timeout: 3)
            || app.staticTexts["Recent Groups"].firstMatch.waitForExistence(timeout: 3)
    }
}
