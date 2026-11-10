#if os(iOS)
import XCTest

final class DesignSystemCallUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testCallControlsAndCancelledDisconnectKeepCall() {
        defer { attachEvidence("Portrait call controls") }
        startStandardCall()
        let mute = app.buttons["standardMuteButton"].firstMatch
        let speaker = app.buttons["standardSpeakerButton"].firstMatch
        let end = app.buttons["standardEndCallButton"].firstMatch
        for control in [mute, speaker, end] {
            XCTAssertTrue(control.waitForExistence(timeout: 5), control.debugDescription)
            XCTAssertTrue(control.isHittable, control.debugDescription)
        }
        // The hero is one element: kind, size and destination, with the state as its value.
        let hero = app.descendants(matching: .any)["standardCallHero"].firstMatch
        XCTAssertTrue(hero.exists, hero.debugDescription)
        XCTAssertTrue(hero.label.hasPrefix("Group · "), hero.label)
        XCTAssertLessThan(hero.frame.maxY, mute.frame.minY, "Controls sit below the hero")
        // No guidance text under the controls; the mute button's own label says Muted.
        XCTAssertFalse(app.staticTexts["standardMicrophoneStatus"].exists)
        mute.tap()
        let microphoneStatus = app.staticTexts["standardMuteState"].firstMatch
        XCTAssertTrue(microphoneStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(microphoneStatus.label, "Muted")
        let previousSpeakerValue = speaker.value as? String
        XCTAssertNotNil(previousSpeakerValue)
        speaker.tap()
        XCTAssertNotEqual(speaker.value as? String, previousSpeakerValue)
        end.tap()
        let cancel = app.alerts.firstMatch.buttons["standardCancelEndCallButton"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.exists)
        cancel.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 3))
        XCTAssertTrue(end.isHittable)
        XCTAssertFalse(app.buttons["standardConnectButton"].exists)
        XCTAssertEqual(microphoneStatus.label, "Muted")
    }

    /// Settings open from named entries: the call's More menu and a row's swipe or menu.
    /// The row tap only connects, so rows carry no pencil or info buttons.
    @MainActor
    func testGroupSettingsOpenFromTheCallMenuAndTheListRow() {
        defer { attachEvidence("Group settings entries") }
        startStandardCall()
        XCTAssertFalse(app.buttons["inviteButton"].exists, "Sharing lives in the More menu")
        let invite = app.openCallMoreMenuItem("callAddMembersButton")
        XCTAssertTrue(invite.exists)
        XCTAssertEqual(invite.label, "Invite Members", "Standard names the intent, not the saved-user mechanism")
        app.buttons["callGroupSettingsButton"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSettingsView"].firstMatch.waitForExistence(timeout: 3))
        // Standard: Invite Members under the members, the same words as the call's menu; Delete Group last.
        XCTAssertEqual(app.buttons["groupSettingsAddMembersButton"].label, "Invite Members")
        XCTAssertEqual(app.buttons["deleteGroupButton"].label, "Delete Group")
        let name = app.textFields["groupSettingsNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        let renamed = "Renamed " + UUID().uuidString.prefix(6)
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + renamed)
        app.buttons["saveGroupSettingsButton"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 3))
        let hero = app.descendants(matching: .any)["standardCallHero"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 3))
        XCTAssertTrue(hero.label.contains(renamed), "The open call shows the new name: \(hero.label)")
        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.exists, "Renaming keeps the call")

        openGroups()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", renamed)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(row.descendants(matching: .any)["directoryRowCallStatus"].firstMatch.exists
                      || app.descendants(matching: .any)["directoryRowCallStatus"].firstMatch.exists, "The live call shows on its row")
        XCTAssertFalse(app.buttons["Edit Name"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manageGroup-")).firstMatch.exists)
        row.swipeLeft()
        let settings = app.buttons["Group Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete"].firstMatch.exists)
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSettingsView"].firstMatch.waitForExistence(timeout: 3))
        attachEvidence("Group settings from the row")
        app.buttons["closeGroupSettingsButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSettingsView"].firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["callAccessoryOpenButton"].firstMatch.exists, "Settings do not end the call")
        // Delete asks first, names the group and says the live connection ends; Cancel keeps it.
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["Delete \(renamed)?"].exists, alert.debugDescription)
        XCTAssertTrue(alert.staticTexts["The current connection ends."].exists)
        XCTAssertEqual(alert.buttons["confirmDeleteDestinationButton"].firstMatch.label, "Disconnect and Delete")
        attachEvidence("Delete a live group asks first")
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertTrue(row.exists, "Cancel keeps the group")
        XCTAssertTrue(app.buttons["callAccessoryOpenButton"].firstMatch.exists, "Cancel keeps the call")
    }

    /// The bar above the tab bar names the call and its state, and offers Mute and End.
    /// Only its End asks first; Cancel keeps the call.
    @MainActor
    func testCallAccessoryShowsStateAndAsksBeforeEnding() {
        defer { attachEvidence("Call accessory") }
        startStandardCall()
        app.closeCallIfOpen()
        let open = app.buttons["callAccessoryOpenButton"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        XCTAssertTrue(open.label.hasPrefix("Design ") && open.label.contains(", "), "Name and state word: \(open.label)")
        let mute = app.buttons["callAccessoryMuteButton"].firstMatch
        let end = app.buttons["callAccessoryEndButton"].firstMatch
        for control in [mute, end] {
            XCTAssertTrue(control.exists && control.isHittable, control.debugDescription)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
        }
        XCTAssertGreaterThanOrEqual(end.frame.minX - mute.frame.maxX, 0, "End sits after Mute")
        mute.tap()
        XCTAssertTrue(open.label.hasSuffix("Muted"), open.label)
        attachEvidence("Call accessory muted")
        end.tap()
        let confirm = app.buttons["callAccessoryConfirmEndButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "End asks first")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Disconnect from Design'")).firstMatch.exists)
        attachEvidence("Call accessory end confirmation")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() } else { app.otherElements["PopoverDismissRegion"].firstMatch.tap() }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertTrue(open.exists, "Cancel keeps the call")
        end.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(open.waitForNonExistence(timeout: 5), "Ending removes the bar")
    }

    @MainActor
    func testChoosingAnotherGroupDuringACallAsksBeforeSwitching() {
        defer { attachEvidence("Switch confirmation") }
        startStandardCall()
        let second = "Second " + UUID().uuidString.prefix(6)
        createGroup(named: second)
        var asked = false
        for row in 0..<2 {
            openGroups()
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-"))
            XCTAssertTrue(rows.element(boundBy: row).waitForExistence(timeout: 3))
            let target = rows.element(boundBy: row)
            let targetName = String(target.label.prefix(12))
            // The accessory above the tab bar names the live call.
            let current = app.buttons["callAccessoryOpenButton"].firstMatch
            XCTAssertTrue(current.waitForExistence(timeout: 3))
            let currentName = current.label
            target.tap()
            let confirm = app.buttons["switchCallConfirmButton"].firstMatch
            guard confirm.waitForExistence(timeout: 2) else {
                XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 3),
                              "Choosing the current call reopens it")
                continue
            }
            asked = true
            // The confirmation names the call that ends and the one that starts.
            XCTAssertTrue(app.staticTexts["Switch connection?"].firstMatch.exists)
            let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Disconnect from'")).firstMatch
            XCTAssertTrue(message.exists, app.debugDescription)
            XCTAssertTrue(message.label.contains(String(currentName.prefix(12))) && message.label.contains(targetName), message.label)
            attachEvidence("Switch confirmation dialog")
            // On iPhone the dialog is a popover without a Cancel button; tapping outside cancels it.
            let cancel = app.buttons["switchCallCancelButton"].firstMatch
            if cancel.exists { cancel.tap() } else { app.otherElements["PopoverDismissRegion"].firstMatch.tap() }
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
            XCTAssertEqual(current.label, currentName, "Cancelling keeps the current call")
            target.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 3))
            confirm.tap()
            XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 5))
            openGroups()
            XCTAssertTrue(current.waitForExistence(timeout: 3))
            XCTAssertTrue(current.label.hasPrefix(targetName), "Switching makes the chosen group the current call")
        }
        XCTAssertTrue(asked, "One of the two groups is not the current call and must ask before switching")
    }

    @MainActor
    func testLandscapeCallControlsRemainFixedWhileDetailsScroll() {
        defer { attachEvidence("Landscape call controls") }
        startStandardCall()
        XCUIDevice.shared.orientation = .landscapeLeft
        let mute = app.buttons["standardMuteButton"].firstMatch
        let speaker = app.buttons["standardSpeakerButton"].firstMatch
        let end = app.buttons["standardEndCallButton"].firstMatch
        let details = app.descendants(matching: .any)["standardCallDetailsScroll"].firstMatch
        let participants = app.staticTexts["standardCallParticipantsHeading"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertTrue(participants.waitForExistence(timeout: 3))
        for control in [mute, speaker, end] { XCTAssertTrue(control.isHittable, control.debugDescription) }
        let originalFrames = [mute.frame, speaker.frame, end.frame]
        let participantsY = participants.frame.minY
        let lower = details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.05, thenDragTo: upper)
        XCTAssertNotEqual(participants.frame.minY, participantsY, "The details must actually scroll")
        for (control, original) in zip([mute, speaker, end], originalFrames) {
            XCTAssertTrue(control.isHittable, control.debugDescription)
            XCTAssertEqual(control.frame.minX, original.minX, accuracy: 1)
            XCTAssertEqual(control.frame.minY, original.minY, accuracy: 1)
        }
    }

    @MainActor
    func testMutedStateIsIndependentAndSpeakerVolumeShowsValue() {
        defer { attachEvidence("Muted state and speaker volume") }
        startStandardCall()
        let mute = app.buttons["standardMuteButton"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        mute.tap()
        let state = app.staticTexts["standardMuteState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.label, "Muted")
        XCTAssertEqual(mute.value as? String, "Muted")
        let value = app.staticTexts["standardSpeakerVolumeValue"].firstMatch
        for _ in 0..<4 where !value.exists { app.swipeUp() }
        XCTAssertTrue(value.waitForExistence(timeout: 3))
        XCTAssertEqual(value.label, "100%")
    }

    @MainActor
    func testLandscapeLargestTextKeepsCallControlsReachable() {
        addTeardownBlock { [weak self] in
            await MainActor.run { self?.attachEvidence("Landscape largest text call") }
        }
        startStandardCall(accessibilityText: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        let mute = app.buttons["standardMuteButton"].firstMatch
        let speaker = app.buttons["standardSpeakerButton"].firstMatch
        let end = app.buttons["standardEndCallButton"].firstMatch
        for control in [mute, speaker, end] {
            XCTAssertTrue(control.waitForExistence(timeout: 5), control.debugDescription)
            XCTAssertTrue(control.isHittable, control.debugDescription)
            XCTAssertTrue(app.frame.contains(control.frame), control.debugDescription)
            XCTAssertGreaterThanOrEqual(control.frame.width, 56)
            XCTAssertGreaterThanOrEqual(control.frame.height, 56)
        }
        XCTAssertFalse(mute.frame.intersects(speaker.frame))
        XCTAssertFalse(speaker.frame.intersects(end.frame))
        let details = app.descendants(matching: .any)["standardCallDetailsScroll"].firstMatch
        let controls = app.descendants(matching: .any)["standardCallFixedControls"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(details.frame.maxY, controls.frame.minY + 1, "Information and controls must occupy separate regions")
        let labels = [("standardMuteState", "Mute"), ("standardSpeakerControlLabel", "Speaker"), ("standardEndControlLabel", "End")].map { id, expected in
            let label = app.staticTexts[id].firstMatch
            XCTAssertTrue(label.exists, label.debugDescription)
            XCTAssertEqual(label.label, expected)
            XCTAssertTrue(app.frame.contains(label.frame), label.debugDescription)
            return label
        }
        for (index, label) in labels.enumerated() {
            for other in labels.dropFirst(index + 1) {
                XCTAssertFalse(label.frame.intersects(other.frame), "Control labels must not overlap")
            }
            for button in [mute, speaker, end] {
                XCTAssertFalse(label.frame.intersects(button.frame), "Control labels and buttons must not overlap")
            }
        }
        let state = app.descendants(matching: .any)["standardCallHero"].firstMatch
        XCTAssertTrue(state.exists, state.debugDescription)
        let originalY = state.frame.minY
        let lower = details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.05, thenDragTo: upper)
        // The list is lazy: scrolling may move the status out of the hierarchy entirely.
        XCTAssertTrue(!state.exists || state.frame.minY != originalY, "The information region must scroll")
        for control in [mute, speaker, end] { XCTAssertTrue(control.isHittable, control.debugDescription) }
    }

    @MainActor
    func testRegularWidthUsesSeparateCallColumns() throws {
        defer { attachEvidence("Regular width call") }
        startStandardCall()
        guard app.frame.width >= 600, app.frame.height >= 500 else {
            throw XCTSkip("Requires an iPad or other regular-width viewport at least 600 by 500 points")
        }
        // Wide screens keep the list and open the call as a single column on its right.
        let hero = app.descendants(matching: .any)["standardCallHero"].firstMatch
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(row.exists && row.isHittable, "The list stays usable beside the call")
        XCTAssertLessThanOrEqual(row.frame.maxX, hero.frame.minX + 1)
        XCTAssertFalse(app.descendants(matching: .any)["standardCallDetailsScroll"].firstMatch.exists,
                       "The call column is one column")
        XCTAssertTrue(app.buttons["standardMuteButton"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["standardSpeakerButton"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.isHittable)
    }

    @MainActor private func attachEvidence(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name + " full screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if let app {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = name + " accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
    }

    @MainActor private func startStandardCall(accessibilityText: Bool = false) {
        app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if accessibilityText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch(); app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 5))
        let groups = app.buttons["groupsTab"].firstMatch
        if groups.exists { groups.tap() }
        else { app.tabBars.buttons["Groups"].firstMatch.tap() }
        let create = app.buttons["standardCreateGroupButton"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let name = app.textFields["savedUsersGroupNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + "Design " + UUID().uuidString.prefix(6))
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor private func openGroups() {
        app.closeCallIfOpen()
        let groups = app.buttons["groupsTab"].firstMatch
        if groups.exists { groups.tap() } else { app.tabBars.buttons["Groups"].firstMatch.tap() }
    }

    @MainActor private func createGroup(named groupName: String) {
        openGroups()
        let create = app.buttons["standardCreateGroupButton"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let name = app.textFields["savedUsersGroupNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + groupName)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForExistence(timeout: 5))
    }
}
#endif
