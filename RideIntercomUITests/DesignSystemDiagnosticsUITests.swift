#if os(iOS)
import XCTest

@MainActor
final class DesignSystemDiagnosticsUITests: XCTestCase {
    func testDiagnosticsMenuAtAccessibilitySizeInLandscape() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "advanced"
        app.launch()
        addTeardownBlock { [weak self] in
            guard app.state == .runningForeground else { return }
            self?.attachScreen("Diagnostics landscape picker teardown")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Diagnostics landscape picker teardown AX"
            hierarchy.lifetime = .keepAlways
            self?.add(hierarchy)
        }
        let tab = app.tabBars.buttons["Diagnostics"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 8)); tab.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        let picker = app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        choose("Applied", in: picker, app: app, capture: true)
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsAppliedCodec"].firstMatch.waitForExistence(timeout: 3))
        choose("Overview", in: picker, app: app, capture: true)
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsCannotHearButton"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["diagnosticsOverviewGrid"].firstMatch.exists, "The summary cards are retired")
        choose("Applied", in: picker, app: app, capture: true)
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsAppliedCodec"].firstMatch.waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    func testDiagnosticsPagesPreserveExistingValuesAndActionsAcrossRotation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "advanced"
        app.launch()
        defer {
            attachScreen("Diagnostics final state")
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        let tab = app.tabBars.buttons["Diagnostics"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 8)); tab.tap()
        let picker = app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsCannotHearButton"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["diagnosticsOverviewGrid"].firstMatch.exists, "The summary cards are retired")

        choose("TX", in: picker, app: app)
        XCTAssertTrue(app.descendants(matching: .any)["liveTransmitPipelineView"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-session-step"].firstMatch.exists)
        attachScreen("Diagnostics TX AX5 portrait")
        choose("RX", in: picker, app: app)
        XCTAssertTrue(app.descendants(matching: .any)["liveReceivePipelineView"].firstMatch.waitForExistence(timeout: 3))
        choose("Network", in: picker, app: app)
        let network = app.staticTexts["networkDiagnosticsSummary"].firstMatch
        XCTAssertTrue(network.waitForExistence(timeout: 3))
        let networkValue = network.label
        let localRoute = app.descendants(matching: .any)["diagnosticsNetworkLocal"].firstMatch
        let internetRoute = app.descendants(matching: .any)["diagnosticsNetworkInternet"].firstMatch
        reveal(localRoute, app: app)
        reveal(internetRoute, app: app)
        XCTAssertFalse(networkValue.isEmpty)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(network.waitForExistence(timeout: 3))
        XCTAssertEqual(network.label, networkValue, "Rotation must preserve the current diagnostic input")
        attachScreen("Diagnostics Network AX5 landscape")
        choose("Applied", in: picker, app: app)
        let codec = app.descendants(matching: .any)["diagnosticsAppliedCodec"].firstMatch
        XCTAssertTrue(codec.waitForExistence(timeout: 3))
        XCTAssertTrue(codec.label.contains("Requested:"), codec.label)
        XCTAssertTrue(codec.label.contains("Applied:"), codec.label)
        let vad = app.staticTexts["diagnosticsAppliedVAD"].firstMatch
        reveal(vad, app: app)
        XCTAssertTrue(vad.label.contains("Not measured"), vad.label)
        let status = app.staticTexts["internetServiceCheckStatus"].firstMatch
        reveal(status, app: app)
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        let before = status.label
        let check = app.buttons["checkInternetService"].firstMatch
        reveal(check, app: app)
        XCTAssertTrue(check.exists)
        XCTAssertFalse(check.isEnabled, "Without credentials the existing service check remains disabled")
        for (identifier, expected) in [
            ("diagnosticsOthersCannotHearButton", "pipeline-session-step"),
            ("diagnosticsCannotHearButton", "diagnosticsReceiveDetails"),
            ("diagnosticsAudioDropsButton", "diagnosticsReceiveDetails"),
            ("diagnosticsAudioDelayedButton", "receive-pipeline-output-step")
        ] {
            choose("Overview", in: picker, app: app)
            let symptom = app.buttons[identifier].firstMatch
            reveal(symptom, app: app)
            symptom.tap()
            XCTAssertTrue(app.descendants(matching: .any)[expected].firstMatch.waitForExistence(timeout: 3))
        }
        choose("Applied", in: picker, app: app)
        reveal(status, app: app)
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.label, before)
    }

    private func choose(_ title: String, in picker: XCUIElement, app: XCUIApplication, capture: Bool = false) {
        XCTAssertTrue(picker.isHittable, picker.debugDescription)
        if capture { attachScreen("Diagnostics picker before \(title)") }
        picker.tap()
        if capture {
            attachScreen("Diagnostics picker choices for \(title)")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Diagnostics picker choices AX \(title)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        let choice = app.buttons[title].firstMatch
        let selection = app.descendants(matching: .any)["diagnosticsPageSelection"].firstMatch
        if selection.waitForExistence(timeout: 2) {
            for _ in 0..<8 where !choice.isHittable { selection.swipeUp() }
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
        for _ in 0..<5 where !choice.isHittable {
            let visible = ["Overview", "TX", "RX", "Network", "Applied"]
                .map { app.buttons[$0].firstMatch }
                .first { $0.exists && $0.isHittable && app.frame.intersection($0.frame).height > 30 }
            guard let visible else { XCTFail("No visible menu item: \(app.debugDescription)"); return }
            visible.swipeUp()
        }
        XCTAssertTrue(choice.isHittable, "Menu choice is outside the viewport: \(choice.debugDescription)")
        choice.tap()
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ target: XCUIElement, app: XCUIApplication) {
        let scroll = app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 3))
        let frame = scroll.frame.intersection(app.frame)
        let picker = app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch
        let tabBar = app.tabBars.firstMatch
        let top = max(frame.minY, picker.frame.maxY) + 8
        let bottom = min(frame.maxY, tabBar.exists ? tabBar.frame.minY : frame.maxY) - 8
        XCTAssertGreaterThan(bottom - top, 20, app.debugDescription)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let lower = origin.withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: top + (bottom - top) * 0.75 - app.frame.minY))
        let upper = origin.withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: top + (bottom - top) * 0.25 - app.frame.minY))
        for _ in 0..<20 where !target.isHittable {
            lower.press(forDuration: 0.05, thenDragTo: upper)
            XCTAssertTrue(picker.exists, "Scrolling must remain on Diagnostics")
        }
        for _ in 0..<20 where !target.isHittable {
            upper.press(forDuration: 0.05, thenDragTo: lower)
            XCTAssertTrue(picker.exists, "Scrolling must remain on Diagnostics")
        }
        XCTAssertTrue(target.isHittable, target.debugDescription)
    }
}
#endif
