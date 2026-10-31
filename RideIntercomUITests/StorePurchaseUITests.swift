#if RIDEINTERCOM_STOREKIT_TESTING && os(iOS)
import XCTest

/// The unavailable fixture intentionally has no product in the StoreKit file.
@MainActor
final class StorePurchaseUITests: XCTestCase {
    func testUnavailableProductsKeepRetryCloseAndRestoreReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_STOREKIT_CATALOG_FIXTURE"] = "unavailable"
        app.launch()
        defer { app.terminate() }
        let settings = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 8)); settings.tap()
        let entry = app.buttons["viewPurchases"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: entry)
        waitForExpectations(timeout: 20)
        entry.tap()
        let unavailable = app.staticTexts["Purchases could not be loaded. Please try again."]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15), app.debugDescription)
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.exists); retry.tap()
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Unavailable products keep Retry and Done"; before.lifetime = .keepAlways; add(before)
        app.buttons["Done"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.isEnabled && entry.isHittable)
        let restore = app.buttons["restorePurchases"]
        XCTAssertTrue(restore.exists && restore.isEnabled && restore.isHittable)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Settings purchase and restore remain reachable"; after.lifetime = .keepAlways; add(after)
    }
}
#endif
