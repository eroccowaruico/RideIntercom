import XCTest

/// The Watch screens from the validation fixtures (RIDEINTERCOM_WATCH_UI_FIXTURE). Nothing reaches
/// the iPhone and no audio starts; the fixture fills the snapshot the iPhone would send.
final class WatchLaunchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func testSavedPeopleListStartsTheScreen() {
        launch("list")
        XCTAssertTrue(element("watchDestinationList").waitForExistence(timeout: 10))
        XCTAssertTrue(element("watchConnectionStatus").exists)
        XCTAssertTrue(app.buttons["watchTarget-haruka"].firstMatch.exists)
        attach("Watch list")
    }

    @MainActor
    func testCallScreenPutsEndAwayFromTalkAndConfirmsIt() {
        launch("in-call")
        let talk = element("watchHoldToTalk")
        XCTAssertTrue(talk.waitForExistence(timeout: 10))
        let end = app.buttons["watchEndCallButton"].firstMatch
        XCTAssertTrue(end.exists)
        XCTAssertLessThan(end.frame.midY, talk.frame.minY, "End sits above the talk panel")
        attach("Watch call")
        end.tap()
        // watchOS shows the dialog's cancel as its Close button.
        XCTAssertTrue(app.staticTexts["End this call?"].firstMatch.waitForExistence(timeout: 3), "Ending asks first")
        XCTAssertTrue(app.buttons["End Call"].firstMatch.exists)
        let close = app.buttons["AX_ActionContentControllerCancelButton"].firstMatch
        XCTAssertTrue(close.exists)
        close.tap()
        XCTAssertTrue(talk.waitForExistence(timeout: 3), "Cancel keeps the call")
    }

    @MainActor
    func testPausedAudioPutsTheReasonOnItsOwnLine() {
        launch("paused")
        let status = element("watchCallStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("Audio paused"), status.label)
        XCTAssertFalse(status.label.contains("—"))
        let detail = element("watchCallStatusDetail")
        XCTAssertTrue(detail.exists)
        XCTAssertEqual(detail.label, "Check your iPhone")
        XCTAssertGreaterThan(detail.frame.minY, status.frame.minY, "The reason is on the next line")
    }

    @MainActor
    func testUnreachableIPhoneOffersRetry() {
        launch("unreachable")
        XCTAssertTrue(element("watchMessage").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watchRetryButton"].firstMatch.exists)
    }

    @MainActor
    func testJapaneseUsesTheDesignTerms() {
        launch("in-call", language: "ja")
        let status = element("watchCallStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("会話中"), status.label)
        attach("Watch call Japanese")
    }

    @MainActor private func launch(_ fixture: String, language: String = "en") {
        app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_WATCH_UI_FIXTURE"] = fixture
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ja" ? "ja_JP" : "en_US"]
        app.launch()
    }

    @MainActor private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
