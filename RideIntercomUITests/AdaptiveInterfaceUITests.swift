#if os(iOS)
import XCTest

/// Runs on iPhone too; the dedicated iPad run covers regular-width tab and sheet presentation.
final class AdaptiveInterfaceUITests: XCTestCase {
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

    @MainActor func testEnglishTabsSheetsAndCallAcrossRotation() { checkInterface(japanese: false) }
    @MainActor func testJapaneseTabsSheetsAndCallAcrossRotation() { checkInterface(japanese: true) }

    @MainActor private func checkInterface(japanese: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"]
        app.launch(); app.activate()
        XCTAssertTrue(element("standardCallScreen").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["diagnosticsTab"].exists)
        tab(japanese ? "ユーザー" : "Users", id: "usersTab")
        XCTAssertTrue(element("standardUsersList").waitForExistence(timeout: 3))
        tab(japanese ? "グループ" : "Groups", id: "groupsTab")
        let create = app.buttons["standardCreateGroupButton"]
        assertVisible(create)
        create.tap()
        let cancel = app.buttons["closeSavedUsersButton"]
        assertVisible(cancel)
        assertVisible(app.buttons["saveUserSelectionButton"])
        screenshot("\(japanese ? "Japanese" : "English") portrait group sheet")
        cancel.tap()
        XCTAssertTrue(element("standardGroupsList").waitForExistence(timeout: 3))

        XCUIDevice.shared.orientation = .landscapeLeft
        assertVisible(create)
        create.tap()
        let field = app.textFields["savedUsersGroupNameField"]
        assertVisible(field)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String)?.count ?? 0) + "Tablet " + UUID().uuidString.prefix(6))
        assertVisible(app.buttons["saveUserSelectionButton"])
        screenshot("\(japanese ? "Japanese" : "English") landscape group sheet with keyboard")
        app.buttons["saveUserSelectionButton"].tap()
        let end = app.buttons["standardEndCallButton"]
        assertVisible(end)
        let mute = app.switches["standardMuteToggle"].firstMatch
        assertVisible(mute)
        // The identified SwiftUI row contains the native switch. Use that control
        // rather than inferring its center from the row's translated layout.
        let nativeMute = mute.switches.firstMatch
        XCTAssertTrue(nativeMute.waitForExistence(timeout: 3), mute.debugDescription)
        let hierarchy = XCTAttachment(string: mute.debugDescription)
        hierarchy.name = "Mute row and native control"; hierarchy.lifetime = .keepAlways
        add(hierarchy)
        if (nativeMute.value as? String) != "1" { nativeMute.tap() }
        XCTAssertEqual(nativeMute.value as? String, "1", mute.debugDescription)
        let mutedText = japanese ? "マイクはミュート中です" : "Microphone muted"
        let status = app.staticTexts["standardMicrophoneStatus"]
        assertVisible(status)
        XCTAssertEqual(status.label, mutedText)
        assertVisible(app.staticTexts["standardSpeakerVolumeLabel"])
        XCTAssertEqual(app.staticTexts["standardSpeakerVolumeLabel"].label, japanese ? "スピーカー音量" : "Speaker Volume")
        screenshot("\(japanese ? "Japanese" : "English") landscape muted call")

        tab(japanese ? "ユーザー" : "Users", id: "usersTab")
        assertVisible(app.buttons["standardCurrentCallButton"])
        app.buttons["standardCurrentCallButton"].tap()
        assertVisible(end)
        assertVisible(status)
        XCTAssertEqual(status.label, mutedText)
        tab(japanese ? "設定" : "Settings", id: "settingsTab")
        assertVisible(app.textFields["localDisplayNameField"])
        screenshot("\(japanese ? "Japanese" : "English") landscape settings")
        let setup = app.buttons["configureInternetConnection"].firstMatch
        assertVisible(setup)
        setup.tap()
        assertVisible(app.textFields["internetWorkerURL"])
        let close = app.buttons["closeInternetConnection"]
        assertVisible(close)
        XCTAssertFalse(app.secureTextFields["internetDeviceToken"].exists)
        screenshot("\(japanese ? "Japanese" : "English") landscape Internet sheet")
        XCUIDevice.shared.orientation = .portrait
        assertVisible(close)
        screenshot("\(japanese ? "Japanese" : "English") portrait Internet sheet")
        close.tap()
        tab(japanese ? "通話" : "Call", id: "callTab")
        assertVisible(end)
        assertVisible(status)
        XCTAssertEqual(status.label, mutedText)
        screenshot("\(japanese ? "Japanese" : "English") portrait call after settings")
        assertVisible(end)
        end.tap()
        assertVisible(app.buttons["standardConnectButton"])
    }

    @MainActor private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func assertVisible(_ control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        _ = control.waitForExistence(timeout: 5)
        // Form/List content may start outside the viewport on a narrow phone,
        // or move down when another Settings section is added. Reveal it using
        // normal scrolling before asserting that the full control is reachable.
        for attempt in 0..<16 {
            if control.exists && control.isHittable && app.frame.contains(control.frame) { break }
            // Lazy rows can be absent from AX entirely. Search the upper
            // part first, then the lower part, without assuming a row exists.
            let hasFrame = control.exists && !control.frame.isEmpty
            let scrollsDown = hasFrame ? control.frame.midY < app.frame.midY : attempt < 3
            let surface: XCUIElement = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollsDown ? 0.3 : 0.7))
            let finish = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollsDown ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: finish)
        }
        XCTAssertTrue(control.exists, control.debugDescription, file: file, line: line)
        XCTAssertTrue(control.isHittable, control.debugDescription, file: file, line: line)
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(control.frame), control.debugDescription, file: file, line: line)
    }

    @MainActor private func tab(_ title: String, id: String) {
        let identified = app.buttons[id].firstMatch
        let target = identified.exists ? identified : app.tabBars.buttons[title].firstMatch
        assertVisible(target)
        target.tap()
    }

    @MainActor private func screenshot(_ title: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
