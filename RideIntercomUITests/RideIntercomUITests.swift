import XCTest
import CryptoKit

final class RideIntercomUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        launchApp()
    }

    private func launchApp(startOnDiagnostics: Bool = false) {
        app = XCUIApplication()
        if name.contains("Adaptive") {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
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
    func testSavedUsersSurviveGroupDeletionAndCanBeReused() throws {
        let groupID = UUID()
        let secret = "ui-test-invitation-key"
        let issuedAt = Date().timeIntervalSince1970
        let inviter = "ui-saved-rider"
        let message = ["1", groupID.uuidString, "Talk Group", secret, inviter, String(format: "%.3f", issuedAt), ""].joined(separator: "|")
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        let token = try JSONSerialization.data(withJSONObject: [
            "version": 1, "groupID": groupID.uuidString, "groupName": "Talk Group", "groupSecret": secret,
            "inviterMemberID": inviter, "issuedAt": issuedAt, "signature": signature
        ])
        let encoded = token.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        app.open(try XCTUnwrap(URL(string: "rideintercom://join?token=\(encoded)")))
        XCTAssertTrue(app.descendants(matching: .any)["remoteParticipantRow0"].firstMatch.waitForExistence(timeout: 5))
        try checkGroupDeletionCanBeExercisedFromUI()
        // Restart only here: this case explicitly verifies persisted users.
        app.terminate(); app.launch(); app.activate()
        openGroupsTab()
        app.buttons["savedUsersButton"].tap()
        let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "selectUser-")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editUser-")).firstMatch.tap()
        let field = app.textFields["savedUserNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "Alex")
        app.buttons["saveUserNameButton"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertTrue(toggle.label.contains("Alex"))
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        attachScreen("Saved Users Selection")
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["remoteParticipantRow0"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.exists)
        XCTAssertTrue(app.buttons["inviteButton"].exists)
        attachScreen("Group Created from Saved User")
        try checkGroupDeletionCanBeExercisedFromUI()
        createTalkGroupAndOpenCall()
        let add = app.buttons["addSavedUsersButton"]
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 3))
        attachScreen("Saved User Added to Existing Group")
        openGroupsTab()
        app.buttons["savedUsersButton"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 3))
        attachScreen("Saved User Removed while Group Remains")
        app.buttons["closeSavedUsersButton"].tap()
        app.buttons["groupRow-Talk Group"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 3))
        try checkGroupDeletionCanBeExercisedFromUI()
        app.terminate(); app.launch(); app.activate()
        openGroupsTab()
        app.buttons["savedUsersButton"].tap()
        XCTAssertFalse(toggle.exists)
        app.buttons["closeSavedUsersButton"].tap()
    }

    @MainActor
    func testAACBitrateChoicesSurviveCodecSwitches() {
        openSettingsTab()
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        let codec = app.segmentedControls.containing(.button, identifier: "PCM 16-bit").firstMatch
        for _ in 0..<8 where !codec.buttons["AAC-ELD"].isHittable { scroll.swipeUp() }
        XCTAssertTrue(app.staticTexts["transmitCodecLabel"].exists)
        XCTAssertTrue(app.staticTexts["rtcAudioSampleRateLabel"].exists)
        codec.buttons["AAC-ELD"].tap()
        let format = app.segmentedControls.containing(.button, identifier: "48 kHz").firstMatch
        for (sampleRate, rates) in [("48 kHz", [48, 64, 80, 96, 112, 128]), ("24 kHz", [32, 48, 64]), ("16 kHz", [48])] {
            format.buttons[sampleRate].tap()
            for otherCodec in ["PCM 16-bit", "Opus", "PCM 16-bit"] {
                codec.buttons[otherCodec].tap()
                codec.buttons["AAC-ELD"].tap()
                let bitrate = app.buttons["aacELDBitRatePicker"].firstMatch
                XCTAssertTrue(bitrate.waitForExistence(timeout: 3))
                bitrate.tap()
                attachScreen("AAC menu \(sampleRate) after \(otherCodec)")
                for rate in [32, 48, 64, 80, 96, 112, 128] {
                    XCTAssertEqual(app.buttons["\(rate) kbps"].firstMatch.exists, rates.contains(rate), "\(sampleRate): \(rate) kbps after \(otherCodec)")
                }
                app.buttons["\(rates.last!) kbps"].firstMatch.tap()
                XCTAssertTrue(bitrate.label.contains("\(rates.last!) kbps") || (bitrate.value as? String)?.contains("\(rates.last!) kbps") == true)
            }
        }
        format.buttons["48 kHz"].tap()
    }

    @MainActor
    func testCorruptGroupStoreRecovery() throws {
        // validate.py supplies corrupt bytes only after the ordinary UI suite,
        // inside its own Simulator and build-specific storage namespace.
        let status = app.descendants(matching: .any)["groupStorageStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["createGroupButton"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["groupErrorLabel"].exists)
        app.buttons["reloadSavedGroupsButton"].tap()
        XCTAssertTrue(status.exists)
        attachScreen("Saved Groups Recovery")
        app.buttons["resetSavedGroupsButton"].tap()
        let cancel = app.alerts.buttons["cancelResetSavedGroupsButton"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        attachScreen("Confirm Saved Groups Reset")
        cancel.tap()
        XCTAssertTrue(status.exists)
        XCTAssertFalse(app.buttons["createGroupButton"].isEnabled)
        app.buttons["resetSavedGroupsButton"].tap()
        app.alerts.buttons["confirmResetSavedGroupsButton"].firstMatch.tap()
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["createGroupButton"].isEnabled)
        createTalkGroupAndOpenCall()
        try checkGroupDeletionCanBeExercisedFromUI()
        attachScreen("Saved Groups Recovered")
    }

    @MainActor
    func testRecoveryWorkflowInOneLaunch() throws {
        // Restore the required route through UI even if a previous run stopped
        // halfway through changing settings. Do not erase application data.
        openSettingsTab()
        let localRoute = app.switches["Local Network"].firstMatch
        XCTAssertTrue(localRoute.waitForExistence(timeout: 3))
        if localRoute.value as? String == "0" { localRoute.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let internetRoute = app.switches["Internet"].firstMatch
        if internetRoute.value as? String == "1" { internetRoute.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        openGroupsTab()
        createTalkGroupAndOpenCall()
        try checkGroupSelectionOpensCallScreen()
        try checkManualAddRiderButtonIsNotShownInCallUI()
        try checkParticipantDeletionIsNotShownForLocalMemberOnly()
        try checkCallKeepsDiagnosticsOutOfPrimaryExperience()
        try checkMuteControlLivesWithHeaderMicrophoneMeter()
        let isolation = app.switches["Master Output Voice Isolation Effect"].firstMatch
        XCTAssertTrue(isolation.waitForExistence(timeout: 3))
        let originalIsolation = isolation.value as? String
        isolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(isolation.value as? String, originalIsolation)
        isolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(isolation.value as? String, originalIsolation)
        try checkVoiceActivityAndHandoverCanBeExercisedFromUI()
        for _ in 0..<3 { try checkDisconnectAndReconnectButtonsTransitionInCall() }
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

    @MainActor
    func testInternetCredentialValidationKeepsTabsUsable() {
        #if os(iOS)
        app.open(URL(string: "rideintercom://join?token=invalid")!)
        XCTAssertTrue(app.descendants(matching: .any)["groupErrorLabel"].firstMatch.waitForExistence(timeout: 5))
        #endif
        checkInternetSettingsRejectUnsecuredURL()
        openGroupsTab()
        openSettingsTab()
        XCTAssertTrue(app.buttons["configureInternetConnection"].exists)
        let internet = app.switches["Internet"].firstMatch
        if internet.value as? String == "0" { internet.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let local = app.switches["Local Network"].firstMatch
        let original = local.value as? String
        if original == "1" { local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertEqual(local.value as? String, "0")
        // Internet-only uses the same controls, even before credentials are configured.
        openGroupsTab()
        createTalkGroupAndOpenCall()
        XCTAssertTrue(app.sliders["masterOutputSlider"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].exists)
        XCTAssertFalse(app.staticTexts["Native audio — meter unavailable"].exists)
        attachScreen("Internet Shared Audio Controls")
        openSettingsTab()
        for _ in 0..<8 where !local.isHittable { app.swipeDown() }
        if original == "1" { local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertEqual(local.value as? String, original)
    }

    @MainActor
    func testAdaptiveDiagnosticsAndConfigurationRemainReachable() {
        openDiagnosticsTab()
        let status = app.staticTexts["internetServiceCheckStatus"]
        for _ in 0..<8 where !status.isHittable { app.swipeUp() }
        XCTAssertTrue(status.exists)
        XCTAssertTrue(app.buttons["checkInternetService"].exists)
        XCTAssertFalse(app.buttons["checkInternetService"].isEnabled)
        let network = app.staticTexts["networkDiagnosticsSummary"]
        for _ in 0..<8 where !network.isHittable { app.swipeUp() }
        XCTAssertTrue(network.isHittable)
        XCTAssertTrue(network.label.contains("Not measured"))
        attachScreen("Diagnostics Large Text Dark")
        openSettingsTab()
        let configure = app.buttons["configureInternetConnection"]
        for _ in 0..<6 where !configure.isHittable { app.swipeUp() }
        configure.tap()
        XCTAssertTrue(app.textFields["internetWorkerURL"].waitForExistence(timeout: 3))
        #if os(iOS)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.app.frame.width > self.app.frame.height && self.app.buttons["closeInternetConnection"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        #endif
        XCTAssertTrue(app.buttons["closeInternetConnection"].waitForExistence(timeout: 3))
        let save = app.buttons["saveInternetConnection"]
        let form = app.collectionViews.containing(.textField, identifier: "internetWorkerURL").firstMatch
        XCTAssertTrue(form.exists)
        for _ in 0..<4 where save.frame.maxY > app.frame.maxY - 20 { form.swipeUp() }
        XCTAssertTrue(save.exists)
        attachScreen("Internet Settings Landscape Large Text")
        XCTAssertLessThanOrEqual(save.frame.maxY, app.frame.maxY - 20)
        app.buttons["closeInternetConnection"].tap()
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        openGroupsTab()
        XCTAssertTrue(waitForVisibleRoot(in: app))
    }

    private func checkInternetSettingsRejectUnsecuredURL() {
        openSettingsTab()
        let configure = app.buttons["configureInternetConnection"]
        for _ in 0..<4 where !configure.isHittable { app.swipeUp() }
        configure.tap()
        let url = app.textFields["internetWorkerURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 3))
        url.tap(); url.typeText("http://example.com")
        let token = app.secureTextFields["internetDeviceToken"]
        token.tap(); token.typeText("invalid-test-token")
        let save = app.buttons["saveInternetConnection"]
        save.tap()
        XCTAssertTrue(app.staticTexts["Could not save. Check the HTTPS URL, device token, and Keychain access."].waitForExistence(timeout: 3))
        app.buttons["closeInternetConnection"].tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 5))
    }

    private func checkSettingsChangesPersistAcrossTabs() {
        openSettingsTab()
        attachScreen("Settings before edits")
        let local = app.switches["Local Network"].firstMatch
        let internet = app.switches["Internet"].firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 3))
        if internet.value as? String == "0" { internet.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let original = local.value as? String
        local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(local.value as? String, original)
        XCTAssertFalse(internet.isEnabled) // The remaining route cannot be disabled.
        openGroupsTab()
        openSettingsTab()
        XCTAssertNotEqual(local.value as? String, original)
        local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(local.value as? String, original)
        let isolation = revealTransmitIsolationToggle()
        XCTAssertTrue(isolation.waitForExistence(timeout: 3))
        let originalIsolation = isolation.value as? String
        isolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(isolation.value as? String, originalIsolation)
        openGroupsTab()
        openSettingsTab()
        let retainedIsolation = revealTransmitIsolationToggle()
        XCTAssertNotEqual(retainedIsolation.value as? String, originalIsolation)
        retainedIsolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(retainedIsolation.value as? String, originalIsolation)
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        let codec = app.segmentedControls.containing(.button, identifier: "PCM 16-bit").firstMatch
        for _ in 0..<6 where !codec.buttons["Opus"].isHittable {
            app.descendants(matching: .any)["settingsScrollView"].firstMatch.swipeUp()
        }
        codec.buttons["Opus"].tap()
        XCTAssertTrue(codec.buttons["Opus"].isSelected)
        codec.buttons["PCM 16-bit"].tap()
        XCTAssertTrue(codec.buttons["PCM 16-bit"].isSelected)
    }

    private func revealTransmitIsolationToggle() -> XCUIElement {
        let toggle = app.switches["Transmit Voice Isolation Effect"].firstMatch
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        for _ in 0..<6 {
            if toggle.exists && toggle.isHittable { break }
            scroll.swipeUp()
        }
        return toggle
    }

    private func attachScreen(_ name: String) {
        #if os(iOS)
        // App-scoped screenshots can crop a rotated sheet using portrait bounds.
        // This is the dedicated test Simulator, so capture its complete screen.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
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
        XCTAssertTrue(app.staticTexts["Unmuted"].exists)
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
        XCTAssertTrue(app.staticTexts["networkDiagnosticsSummary"].waitForExistence(timeout: 3))

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

        revealSettingsPanelIfNeeded(identifier: "audioIOPanel")
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
        revealSettingsPanelIfNeeded(identifier: "audioIOPanel")
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
                if app.descendants(matching: .any)["audioPathSummary"].firstMatch.isHittable { break }
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
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        if !scroll.exists {
            let radio = app.radioButtons["settingsTab"].firstMatch
            if radio.exists { radio.tap() }
            else {
                let identified = app.buttons["settingsTab"].firstMatch
                let button = identified.exists ? identified : app.tabBars.buttons["Settings"].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 3))
                button.tap()
            }
        }
        guard scroll.waitForExistence(timeout: 5) else {
            XCTFail("Settings tab did not open"); return
        }
        for _ in 0..<6 {
            let toggle = app.switches["Local Network"].firstMatch
            if toggle.exists && toggle.isHittable { break }
            scroll.swipeDown()
        }
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
