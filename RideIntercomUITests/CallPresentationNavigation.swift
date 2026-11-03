import XCTest

/// The call is not a tab: it opens over the lists as a sheet (iPhone) or a column (iPad, Mac).
extension XCUIApplication {
    /// The tab bar sits under the call sheet on iPhone, so close the call before switching tabs.
    func closeCallIfOpen() {
        let close = buttons["closeCallButton"].firstMatch
        guard close.exists, close.isHittable else { return }
        close.tap()
        _ = close.waitForNonExistence(timeout: 3)
    }

    /// Reopens the current call from the accessory above the tab bar (a toolbar button on Mac),
    /// or Advanced's Current Call row.
    func openCurrentCall() {
        if buttons["closeCallButton"].firstMatch.exists { return }
        let accessory = buttons["callAccessoryOpenButton"].firstMatch
        if accessory.waitForExistence(timeout: 3) { accessory.tap(); return }
        let current = buttons["standardCurrentCallButton"].firstMatch
        if current.waitForExistence(timeout: 3) { current.tap() }
    }

    /// Opens the call's More menu (settings, adding members, the invitation) and returns one item.
    @discardableResult
    func openCallMoreMenuItem(_ identifier: String) -> XCUIElement {
        let menu = buttons["callMoreMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let item = buttons[identifier].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), item.debugDescription)
        return item
    }
}
