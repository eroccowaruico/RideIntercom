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

    @MainActor private func startStandardCall() {
        app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
