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
        mute.tap()
        let microphoneStatus = app.staticTexts["standardMicrophoneStatus"].firstMatch
        XCTAssertTrue(microphoneStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(microphoneStatus.label, "Microphone muted")
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
        XCTAssertEqual(microphoneStatus.label, "Microphone muted")
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
        let state = app.staticTexts["standardCallStatus"].firstMatch
        XCTAssertTrue(state.exists, state.debugDescription)
        let originalY = state.frame.minY
        let lower = details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.05, thenDragTo: upper)
        XCTAssertNotEqual(state.frame.minY, originalY, "The information region must scroll")
        for control in [mute, speaker, end] { XCTAssertTrue(control.isHittable, control.debugDescription) }
    }

    @MainActor
    func testRegularWidthUsesSeparateCallColumns() throws {
        defer { attachEvidence("Regular width call") }
        startStandardCall()
        guard app.frame.width >= 600, app.frame.height >= 500 else {
            throw XCTSkip("Requires an iPad or other regular-width viewport at least 600 by 500 points")
        }
        let hero = app.descendants(matching: .any)["standardCallHero"].firstMatch
        let details = app.descendants(matching: .any)["standardCallDetailsScroll"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(hero.frame.maxX, details.frame.minX + 1)
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
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForExistence(timeout: 5))
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
}
#endif
