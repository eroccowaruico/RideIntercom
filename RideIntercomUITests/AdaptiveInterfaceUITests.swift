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

    /// On wide screens rows stay at most 640 pt and centered while the list itself spans the area.
    @MainActor func testListsAndSettingsKeepReadableWidth() {
        app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch(); app.activate()
        // Switch tabs in portrait and rotate only to measure; the tab bar moves in landscape.
        tab("ユーザー", id: "usersTab")
        let users = element("standardUsersList")
        XCTAssertTrue(users.waitForExistence(timeout: 5))
        // A fresh install has no rows to measure: opening and cancelling a new invitation leaves one row.
        if !users.cells.firstMatch.waitForExistence(timeout: 2) {
            app.buttons["inviteContactButton"].firstMatch.tap()
            let close = app.buttons["closeContactInvitationButton"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
        }
        checkBothOrientations("Users") { self.assertReadableWidth(users.cells.firstMatch, in: users) }
        tab("設定", id: "settingsTab")
        let settings = element("settingsScrollView")
        let nameCell = app.cells.containing(.button, identifier: "localDisplayNameRow").firstMatch
        checkBothOrientations("Settings") { self.assertReadableWidth(nameCell, in: settings) }
    }

    @MainActor private func checkBothOrientations(_ name: String, _ check: () -> Void) {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            check()
            screenshot("\(name) \(orientation == .portrait ? "portrait" : "landscape")")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor private func assertReadableWidth(_ row: XCUIElement, in list: XCUIElement,
                                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        // Rotation animates; let the layout settle before measuring.
        for _ in 0..<20 where row.frame.width > 641 { usleep(200_000) }
        XCTAssertLessThanOrEqual(row.frame.width, 641, "Rows stop at the readable width", file: file, line: line)
        if XCUIDevice.shared.orientation.isPortrait {
            XCTAssertEqual(row.frame.midX, list.frame.midX, accuracy: 2, "Rows are centered", file: file, line: line)
            if UIDevice.current.userInterfaceIdiom == .phone {
                // The system margin stays, so sections are inset rounded groups, not edge-to-edge rows.
                XCTAssertGreaterThanOrEqual(row.frame.minX - list.frame.minX, 16, "Rows keep the side margin",
                                            file: file, line: line)
            }
        } else if UIDevice.current.userInterfaceIdiom == .pad {
            // The list runs under the floating sidebar; rows center in the area beside it.
            XCTAssertGreaterThan(row.frame.midX, list.frame.midX + 40, "Rows clear the sidebar", file: file, line: line)
        }
        if app.frame.width > 800 {
            XCTAssertGreaterThan(list.frame.width, 700, "The list itself spans the area", file: file, line: line)
        }
    }

    @MainActor private func checkInterface(japanese: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"]
        app.launch(); app.activate()
        XCTAssertTrue(element("standardUsersList").waitForExistence(timeout: 5))
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
        let mute = app.buttons["standardMuteButton"].firstMatch
        assertVisible(mute)
        mute.tap()
        let mutedText = japanese ? "ミュート中" : "Muted"
        let status = app.staticTexts["standardMuteState"].firstMatch
        assertVisible(status)
        XCTAssertEqual(status.label, mutedText)
        assertVisible(app.sliders["standardVolumeSlider"])
        XCTAssertEqual(app.sliders["standardVolumeSlider"].label, japanese ? "音量" : "Volume")
        XCTAssertEqual(app.staticTexts["standardSpeakerControlLabel"].label, japanese ? "消音" : "Silence")
        screenshot("\(japanese ? "Japanese" : "English") landscape muted call")

        tab(japanese ? "ユーザー" : "Users", id: "usersTab")
        // The accessory above the tab bar replaces a Current Call row in the lists.
        XCTAssertFalse(app.buttons["standardCurrentCallButton"].exists)
        let accessory = app.buttons["callAccessoryOpenButton"].firstMatch
        assertVisible(accessory)
        accessory.tap()
        assertVisible(end)
        assertVisible(status)
        XCTAssertEqual(status.label, mutedText)
        tab(japanese ? "設定" : "Settings", id: "settingsTab")
        let nameRow = app.buttons["localDisplayNameRow"].firstMatch
        revealInSettings(nameRow)
        assertVisible(nameRow)
        screenshot("\(japanese ? "Japanese" : "English") landscape settings")
        // Internet setup lives in Advanced Settings for Developers.
        let developer = app.buttons["moreSettingsLink"].firstMatch
        revealInSettings(developer)
        assertVisible(developer)
        developer.tap()
        let setup = app.buttons["configureInternetConnection"].firstMatch
        revealInSettings(setup)
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
        let confirmEnd = app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch
        assertVisible(confirmEnd)
        confirmEnd.tap()
        XCTAssertTrue(end.waitForNonExistence(timeout: 3), "Ending the call returns to the list")
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

    /// In landscape the bars and the call accessory leave a short visible band.
    /// Scroll in small steps toward the row so it stops inside the band instead of
    /// overshooting under the navigation bar.
    @MainActor private func revealInSettings(_ element: XCUIElement) {
        // The developer sub-page is its own Form without the Settings root identifier.
        let root = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        let form = root.exists ? root : app.collectionViews.firstMatch
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            let below = !element.exists || element.frame.midY > form.frame.midY
            let from = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.5 : 0.35))
            let to = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.35 : 0.5))
            from.press(forDuration: 0.3, thenDragTo: to)
        }
    }

    @MainActor private func tab(_ title: String, id: String) {
        if id == "callTab" { app.openCurrentCall(); return }
        app.closeCallIfOpen()
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
