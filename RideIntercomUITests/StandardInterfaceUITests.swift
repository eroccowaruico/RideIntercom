import XCTest

final class StandardInterfaceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate(); app = nil }

    @MainActor
    func testInvitationFailureExplainsRecoveryInBothEnglishLayouts() {
        checkInvitationFailure(japanese: false)
    }

    @MainActor
    func testInvitationFailureExplainsRecoveryInBothJapaneseLayouts() {
        checkInvitationFailure(japanese: true)
    }

    @MainActor private func checkInvitationFailure(japanese: Bool) {
        #if os(iOS)
        launch(japanese: japanese)
        let message = japanese
            ? "この招待を確認できませんでした。送信者に新しい招待を依頼してください。"
            : "This invitation could not be verified. Ask the sender for a new invitation."
        let url = URL(string: "rideintercom://join?token=invalid")!
        app.open(url)
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5))
        screenshot("Invitation recovery in Standard")
        tab(japanese ? "設定" : "Settings", id: "settingsTab")
        selectLayout(japanese ? "詳細" : "Advanced")
        // open(URL) may relaunch and reapply the Standard launch fixture.
        // Keep this process and verify the actual Advanced error surface.
        tab(japanese ? "通話" : "Call", id: "callTab")
        XCTAssertFalse(app.descendants(matching: .any)["standardCallScreen"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["groupErrorLabel"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5))
        screenshot("Invitation recovery in Advanced")
        #endif
    }

    #if os(iOS)
    @MainActor
    func testStandardContactShareCancelAndCopyDoNotRegisterUsers() throws {
        launch()
        tab("Groups", id: "groupsTab")
        let originalGroups = contactGroupRows().count
        tab("Users", id: "usersTab")
        let originalUsers = contactUserRows().count
        let originalPending = contactPendingIDs()
        let plus = app.buttons["inviteContactButton"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 3))
        plus.tap()
        let share = app.buttons["shareContactInvitationButton"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        XCTAssertEqual(share.label, "Share Invitation")
        screenshot("Standard contact invitation before native sharing")
        share.tap()
        let copy = nativeInvitationCopyAction()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        screenshot("Contact invitation native sharing")
        app.swipeDown()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        share.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        app.buttons["closeContactInvitationButton"].tap()
        XCTAssertEqual(contactUserRows().count, originalUsers)
        XCTAssertEqual(contactPendingIDs().subtracting(originalPending).count, 1,
                       "Cancel and Copy reuse the one explicitly created pending invitation")
        tab("Groups", id: "groupsTab")
        XCTAssertEqual(contactGroupRows().count, originalGroups)
        tab("Users", id: "usersTab")
        screenshot("Shared contact invitation remains pending without a fabricated user")
    }

    @MainActor
    func testJapaneseContactPreviewCancelThenAcceptPersistsOnlyTheInviter() throws {
        launch(japanese: true)
        tab("グループ", id: "groupsTab")
        let originalGroups = contactGroupRows().count
        tab("ユーザー", id: "usersTab")
        let originalUsers = contactUserRows().count
        let originalPending = contactPendingIDs()
        let suffix = String(UUID().uuidString.prefix(8))
        let inviterName = "招待者 " + suffix
        let url = try InvitationURLFixture.make(inviter: "ui-contact-" + suffix, sharedName: inviterName, contact: true)
        app.open(url)
        let preview = app.descendants(matching: .any)["contactInvitationPreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[inviterName].firstMatch.exists)
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        let cancel = app.buttons["cancelContactInvitationButton"].firstMatch
        XCTAssertEqual(accept.label, "招待を受け入れる")
        XCTAssertEqual(cancel.label, "キャンセル")
        screenshot("Japanese signed contact invitation preview")
        cancel.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 3))
        tab("ユーザー", id: "usersTab")
        XCTAssertEqual(contactUserRows().count, originalUsers)
        XCTAssertEqual(contactPendingIDs(), originalPending)
        XCTAssertFalse(app.staticTexts[inviterName].exists)
        app.open(url)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[inviterName].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(contactUserRows().count, originalUsers + 1)
        screenshot("Japanese accepted contact saved while notification remains separate")
        tab("グループ", id: "groupsTab")
        XCTAssertEqual(contactGroupRows().count, originalGroups)
        app.terminate(); app.launch(); app.activate()
        tab("ユーザー", id: "usersTab")
        XCTAssertTrue(app.staticTexts[inviterName].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(contactUserRows().count, originalUsers + 1)
    }

    @MainActor
    func testContactPendingRetryAndLocalCancellationKeepAnExistingCall() throws {
        launch()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let groupName = "Contact waiting " + UUID().uuidString.prefix(6)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + groupName)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        let mute = app.buttons["standardMuteButton"].firstMatch
        if mute.value as? String != "Muted" { mute.tap() }
        tab("Users", id: "usersTab")
        let originalUsers = contactUserRows().count
        let previousPending = contactPendingIDs()
        let plus = app.buttons["inviteContactButton"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 3))
        plus.tap()
        XCTAssertTrue(app.buttons["closeContactInvitationButton"].waitForExistence(timeout: 3))
        app.buttons["closeContactInvitationButton"].tap()
        let added = try XCTUnwrap(contactPendingIDs().subtracting(previousPending).first)
        let row = app.buttons[added].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        let retry = app.buttons["retryContactInvitationButton"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        retry.tap()
        let status = app.staticTexts["contactInvitationStatus"].firstMatch
        XCTAssertEqual(status.label, "Waiting for the current call to end.")
        screenshot("Contact retry waits while the current call remains connected")
        app.buttons["cancelPendingContactInvitationButton"].tap()
        let confirm = app.alerts.buttons["confirmCancelContactInvitationButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "on this device")).firstMatch.exists)
        screenshot("Contact cancellation describes local retries")
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertEqual(contactUserRows().count, originalUsers)
        tab("Call", id: "callTab")
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[groupName].firstMatch.exists)
        XCTAssertEqual(mute.value as? String, "Muted")
        app.buttons["standardEndCallButton"].tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
    }

    @MainActor private func contactUserRows() -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-"))
    }
    @MainActor private func contactGroupRows() -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-"))
    }
    @MainActor private func contactPendingIDs() -> Set<String> {
        Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pendingContactInvitation-")).allElementsBoundByIndex.map(\.identifier))
    }
    @MainActor private func nativeInvitationCopyAction() -> XCUIElement {
        app.cells.matching(NSPredicate(format: "label == 'Copy' OR label == 'Copy Link'")).firstMatch
    }
    #endif

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
        let mute = app.buttons["standardMuteButton"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 3))
        mute.tap()
        XCTAssertTrue(app.staticTexts["standardMicrophoneStatus"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["standardMicrophoneStatus"].label, "Microphone muted")
        tab("Settings", id: "settingsTab")
        assertPurchasesUnavailable("Not Available Yet")
        #if os(iOS)
        let liveActivity = app.switches["liveActivityToggle"].firstMatch
        for _ in 0..<6 where !liveActivity.isHittable { app.swipeUp() }
        XCTAssertTrue(liveActivity.waitForExistence(timeout: 3))
        XCTAssertEqual(liveActivity.value as? String, "0")
        liveActivity.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(liveActivity.value as? String, "1")
        liveActivity.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(liveActivity.value as? String, "0")
        #endif
        selectLayout("Advanced")
        XCTAssertTrue(app.tabBars.buttons["Diagnostics"].exists || app.buttons["diagnosticsTab"].exists)
        tab("Users", id: "usersTab")
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
        tab("Groups", id: "groupsTab")
        XCTAssertTrue(app.descendants(matching: .any)["standardGroupsList"].firstMatch.waitForExistence(timeout: 3))
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
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
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
    func testAdvancedCallLeavesGroupCreationInGroups() {
        launch()
        tab("Settings", id: "settingsTab")
        selectLayout("Advanced")
        tab("Call", id: "callTab")
        // A previous run can retain a selected call. Both states keep management
        // out of Call; chooser navigation is asserted when no call is selected.
        let empty = app.descendants(matching: .any)["advancedCallEmptyState"].firstMatch
        let selected = app.descendants(matching: .any)["callScreen"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 3) || selected.exists)
        for identifier in ["createGroupButton", "standardCreateGroupButton", "showGroupsButton", "groupSelectionList"] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].firstMatch.exists,
                           "Advanced Call exposes a group management entry: \(identifier)")
        }
        if empty.exists {
            let chooseUser = app.buttons["chooseUserButton"].firstMatch
            let chooseGroup = app.buttons["chooseGroupButton"].firstMatch
            XCTAssertEqual(chooseUser.label, "Choose a User")
            XCTAssertEqual(chooseGroup.label, "Choose a Group")
            screenshot("Advanced Call without a selected destination")
            chooseUser.tap()
            XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
            tab("Call", id: "callTab")
            chooseGroup.tap()
        } else {
            tab("Groups", id: "groupsTab")
        }
        let groups = app.descendants(matching: .any)["standardGroupsList"].firstMatch
        XCTAssertTrue(groups.waitForExistence(timeout: 3))
        let groupRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-"))
        let previousCount = groupRows.count
        let create = app.buttons["standardCreateGroupButton"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        screenshot("Advanced Groups new group form")
        app.buttons["closeSavedUsersButton"].tap()
        XCTAssertTrue(groups.waitForExistence(timeout: 3))
        XCTAssertFalse(name.exists)
        XCTAssertEqual(groupRows.count, previousCount, "Cancel keeps the saved groups unchanged")

        create.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let groupName = "Advanced Groups " + UUID().uuidString.prefix(6)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + groupName)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        let disconnect = app.buttons["disconnectButton"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        for identifier in ["createGroupButton", "standardCreateGroupButton", "showGroupsButton", "groupSelectionList"] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].firstMatch.exists,
                           "Creating from Groups must return to Call without management entries: \(identifier)")
        }
        screenshot("Advanced Call after creating a named group from Groups")
        disconnect.tap()
        XCTAssertTrue(app.buttons["connectButton"].firstMatch.waitForExistence(timeout: 5))
        tab("Groups", id: "groupsTab")
        let created = app.buttons.containing(.staticText, identifier: groupName).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 3))
        created.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertFalse(created.exists)
    }

    @MainActor
    func testStandardDestinationStaysCenteredWhenRotating() {
        #if os(iOS)
        launch()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let destination = "Weekend Riders " + UUID().uuidString.prefix(4)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + destination)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        let title = app.staticTexts[destination].firstMatch
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = self.app.frame
                return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            XCTAssertTrue(title.waitForExistence(timeout: 3))
            XCTAssertTrue(title.isHittable)
            let hero = app.descendants(matching: .any)["standardCallHero"].firstMatch
            XCTAssertTrue(hero.waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertEqual(title.frame.midX, hero.frame.midX, accuracy: 4,
                           "The destination stays centered within its hero after rotating")
            if orientation.isLandscape {
                let details = app.descendants(matching: .any)["standardCallDetailsScroll"].firstMatch
                XCTAssertTrue(details.waitForExistence(timeout: 3))
                XCTAssertLessThanOrEqual(hero.frame.maxX, details.frame.minX + 1,
                                         "The hero belongs to the fixed left column")
            }
            screenshot("Standard destination centered after rotation \(orientation.rawValue)")
        }
        XCUIDevice.shared.orientation = .portrait
        app.buttons["standardEndCallButton"].tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["standardConnectButton"].waitForExistence(timeout: 3))
        tab("Groups", id: "groupsTab")
        let row = app.buttons.containing(.staticText, identifier: destination).firstMatch
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(row.exists)
        #endif
    }

    @MainActor
    func testStandardSettingsSeparatesRoutineControlsAndConfirmsReset() {
        launch()
        tab("Settings", id: "settingsTab")
        XCTAssertFalse(app.descendants(matching: .any)["interfaceModePicker"].firstMatch.exists)

        let communication = app.buttons["communicationSettingsLink"].firstMatch
        revealStandardSettingsControl(communication)
        communication.tap()
        XCTAssertTrue(app.navigationBars["Communication"].waitForExistence(timeout: 3))
        screenshot("English Communication after navigation")
        let communicationTree = XCTAttachment(string: app.debugDescription)
        communicationTree.name = "English Communication accessibility tree"
        communicationTree.lifetime = .keepAlways
        add(communicationTree)
        XCTAssertTrue(app.switches["Local Network"].firstMatch.exists)
        XCTAssertTrue(app.switches["Internet"].firstMatch.exists)
        screenshot("Standard Communication settings in English")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let vad = app.descendants(matching: .any)["vadSensitivityPicker"].firstMatch
        revealStandardSettingsControl(vad)
        let noisy = vad.buttons["Noisy"].firstMatch
        XCTAssertTrue(noisy.waitForExistence(timeout: 3))
        noisy.tap()
        XCTAssertTrue(noisy.isSelected)
        screenshot("Standard routine settings with Noisy selected")

        let more = app.buttons["moreSettingsLink"].firstMatch
        revealStandardSettingsControl(more)
        more.tap()
        XCTAssertTrue(app.navigationBars["More Settings"].waitForExistence(timeout: 3))
        let layout = app.descendants(matching: .any)["interfaceModePicker"].firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["audioSessionPanel"].firstMatch.exists)
        let codec = app.descendants(matching: .any)["transmitCodecPanel"].firstMatch
        revealStandardSettingsControl(codec)
        XCTAssertTrue(codec.exists)
        for identifier in ["vadSensitivityPicker", "resetAllSettingsButton", "communicationSettingsLink",
                           "communicationPanel", "localNetworkRouteToggle", "internetRouteToggle"] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].firstMatch.exists,
                           "Routine control duplicated in More Settings: \(identifier)")
        }
        screenshot("Standard More Settings contains specialist audio settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let reset = app.buttons["resetAllSettingsButton"].firstMatch
        revealStandardSettingsControl(reset)
        reset.tap()
        let cancel = app.alerts.buttons["cancelResetAllSettingsButton"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        screenshot("Standard reset confirmation in English")
        cancel.tap()
        revealStandardSettingsControl(vad)
        XCTAssertTrue(noisy.isSelected, "Cancel keeps the selected VAD sensitivity")
        revealStandardSettingsControl(reset)
        reset.tap()
        let confirm = app.alerts.buttons["confirmResetAllSettingsButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        revealStandardSettingsControl(more)
        more.tap()
        XCTAssertTrue(layout.waitForExistence(timeout: 3))
        XCTAssertTrue(layout.label.contains("Standard") || (layout.value as? String)?.contains("Standard") == true,
                      "Reset keeps the selected layout")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        revealStandardSettingsControl(vad)
        XCTAssertTrue(vad.buttons["Standard"].firstMatch.isSelected,
                       "Confirmed reset restores the default VAD sensitivity")
        let recording = app.buttons["audioCheckButton"].firstMatch
        revealStandardSettingsControl(recording)
        XCTAssertTrue(recording.exists)
        screenshot("Standard Settings after confirmed reset")
    }

    @MainActor
    func testStandardJapaneseCommunicationAndResetCancellation() {
        launch(japanese: true)
        tab("設定", id: "settingsTab")
        let communication = app.buttons["communicationSettingsLink"].firstMatch
        revealStandardSettingsControl(communication)
        XCTAssertTrue(communication.label.contains("通信経路"))
        communication.tap()
        XCTAssertTrue(app.navigationBars["通信経路"].waitForExistence(timeout: 3))
        screenshot("Japanese Communication after navigation")
        let communicationTree = XCTAttachment(string: app.debugDescription)
        communicationTree.name = "Japanese Communication accessibility tree"
        communicationTree.lifetime = .keepAlways
        add(communicationTree)
        let local = app.switches["近距離"].firstMatch
        let internet = app.switches["インターネット"].firstMatch
        XCTAssertTrue(local.exists)
        XCTAssertTrue(internet.exists)
        XCTAssertEqual(local.label, "近距離")
        XCTAssertEqual(internet.label, "インターネット")
        screenshot("Japanese Standard Communication settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let reset = app.buttons["resetAllSettingsButton"].firstMatch
        revealStandardSettingsControl(reset)
        XCTAssertEqual(reset.label, "すべての設定をリセット")
        reset.tap()
        XCTAssertTrue(app.alerts.staticTexts["すべての設定をリセットしますか？"].firstMatch.waitForExistence(timeout: 3))
        let cancel = app.alerts.buttons["cancelResetAllSettingsButton"].firstMatch
        XCTAssertEqual(cancel.label, "キャンセル")
        XCTAssertEqual(app.alerts.buttons["confirmResetAllSettingsButton"].firstMatch.label, "すべての設定をリセット")
        screenshot("Japanese Standard reset confirmation")
        cancel.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let recording = app.buttons["audioCheckButton"].firstMatch
        revealStandardSettingsControl(recording)
        XCTAssertEqual(recording.label, "5秒録音して再生")
    }

    @MainActor
    func testStandardCommunicationSummaryAndLayoutRoundTripInLandscape() {
        #if os(iOS)
        defer { XCUIDevice.shared.orientation = .portrait }
        for japanese in [false, true] {
            if app != nil { app.terminate() }
            launch(japanese: japanese)
            XCUIDevice.shared.orientation = .landscapeLeft
            tab(japanese ? "設定" : "Settings", id: "settingsTab")
            let link = app.buttons["communicationSettingsLink"].firstMatch
            revealStandardSettingsControl(link)
            link.tap()
            let localName = japanese ? "近距離" : "Local Network"
            let internetName = japanese ? "インターネット" : "Internet"
            let local = app.switches[localName].firstMatch
            let internet = app.switches[internetName].firstMatch
            XCTAssertTrue(local.waitForExistence(timeout: 3))
            XCTAssertTrue(internet.waitForExistence(timeout: 3))
            if internet.value as? String != "1" { XCTAssertTrue(internet.isEnabled); internet.switches.firstMatch.tap() }
            if local.value as? String != "1" { XCTAssertTrue(local.isEnabled); local.switches.firstMatch.tap() }
            XCTAssertEqual(local.value as? String, "1")
            XCTAssertEqual(internet.value as? String, "1")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            revealStandardSettingsControl(link)
            XCTAssertTrue(link.label.contains(localName), link.debugDescription)
            XCTAssertTrue(link.label.contains(internetName), link.debugDescription)
            screenshot("Standard communication both routes landscape")
            link.tap()
            XCTAssertTrue(local.isEnabled)
            local.switches.firstMatch.tap()
            XCTAssertEqual(local.value as? String, "0")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            revealStandardSettingsControl(link)
            XCTAssertFalse(link.label.contains(localName), link.debugDescription)
            XCTAssertTrue(link.label.contains(internetName), link.debugDescription)
            screenshot("Standard communication Internet only landscape")
            link.tap()
            local.switches.firstMatch.tap()
            XCTAssertEqual(local.value as? String, "1")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            selectLayout(japanese ? "詳細" : "Advanced")
            selectLayout(japanese ? "標準" : "Standard")
            revealStandardSettingsControl(link)
            XCTAssertTrue(link.label.contains(localName), link.debugDescription)
            XCTAssertTrue(link.label.contains(internetName), link.debugDescription)
        }
        #endif
    }

    @MainActor private func revealStandardSettingsControl(_ control: XCUIElement) {
        #if os(iOS)
        let form = app.collectionViews.firstMatch
        #else
        let form = app.scrollViews.firstMatch
        #endif
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        let lower = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let upper = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        // Keep the gesture inside the Form, clear of landscape system edges.
        for _ in 0..<20 where !control.isHittable { lower.press(forDuration: 0.05, thenDragTo: upper) }
        for _ in 0..<20 where !control.isHittable { upper.press(forDuration: 0.05, thenDragTo: lower) }
        XCTAssertTrue(control.waitForExistence(timeout: 3))
        XCTAssertTrue(control.isHittable, control.debugDescription)
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
        if app.descendants(matching: .any)["settingsScrollView"].firstMatch.exists,
           !app.tabBars.buttons["Diagnostics"].exists && !app.buttons["diagnosticsTab"].exists {
            let more = app.buttons["moreSettingsLink"].firstMatch
            revealStandardSettingsControl(more)
            more.tap()
        }
        let button = app.buttons["configureInternetConnection"].firstMatch
        revealStandardSettingsControl(button)
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
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let signOut = app.buttons["signOutButton"]
        revealStandardSettingsControl(signOut)
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
        let goingAdvanced = title == "Advanced" || title == "詳細"
        XCTAssertTrue(goingAdvanced || title == "Standard" || title == "標準", "Unknown layout: \(title)")
        if goingAdvanced && app.descendants(matching: .any)["settingsScrollView"].firstMatch.exists {
            let more = app.buttons["moreSettingsLink"].firstMatch
            revealStandardSettingsControl(more)
            more.tap()
        }
        let picker = app.descendants(matching: .any)["interfaceModePicker"].firstMatch
        for _ in 0..<6 where !picker.isHittable { app.swipeDown() }
        XCTAssertTrue(picker.waitForExistence(timeout: 3)); picker.tap()
        let choice = app.buttons[title].firstMatch
        if choice.exists { choice.tap() } else {
            let menu = app.menuItems[title].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 3)); menu.tap()
        }
        let settings = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Switch returns to Settings")
        if goingAdvanced {
            XCTAssertTrue(app.descendants(matching: .any)["interfaceModePicker"].firstMatch.waitForExistence(timeout: 3))
            screenshot("Advanced Settings root after layout switch")
        } else {
            screenshot("Standard Settings root after layout switch")
            revealStandardSettingsControl(app.buttons["moreSettingsLink"].firstMatch)
        }
    }

    @MainActor private func assertPurchasesUnavailable(_ title: String) {
        let status = app.descendants(matching: .any)["purchaseStatus"].firstMatch
        for _ in 0..<5 where !status.exists { app.swipeUp() }
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains(title) || (status.value as? String)?.contains(title) == true || status.staticTexts[title].exists, status.debugDescription)
        XCTAssertFalse(app.buttons["restorePurchases"].exists)
    }

    @MainActor private func screenshot(_ title: String) {
        #if os(iOS)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
