//
//  RideIntercomUITestsLaunchTests.swift
//  RideIntercomUITests
//
//  Created by Naohito Sasao on 2026/04/18.
//

import XCTest

final class RideIntercomUITestsLaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        app.activate()
        defer { app.terminate() }

        XCTAssertTrue(
            waitForVisibleRoot(in: app),
            "Expected the app to launch into a visible root screen"
        )
    }

    private func waitForVisibleRoot(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["groupSelectionList"].firstMatch.waitForExistence(timeout: 3)
            || app.buttons["createGroupButton"].firstMatch.waitForExistence(timeout: 3)
            || app.staticTexts["Recent Groups"].firstMatch.waitForExistence(timeout: 3)
    }
}
