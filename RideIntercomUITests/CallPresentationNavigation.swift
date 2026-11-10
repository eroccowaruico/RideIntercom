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

    /// Advanced: opens the call's More menu and returns one item. Standard has no menu: its settings
    /// button sits in the toolbar and Invite Members under the members, so the item is returned directly.
    @discardableResult
    func openCallMoreMenuItem(_ identifier: String) -> XCUIElement {
        let menu = buttons["callMoreMenu"].firstMatch
        if menu.waitForExistence(timeout: 2) { menu.tap() }
        let item = buttons[identifier].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), item.debugDescription)
        return item
    }

    /// A list row's Delete asks first; confirm it.
    func confirmDestinationDelete() {
        let confirm = alerts.firstMatch.buttons["confirmDeleteDestinationButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Deleting a row asks first")
        confirm.tap()
    }

    /// Deletes a group row. Advanced swipes to Delete; Standard's swipe offers Group Settings only,
    /// so deleting happens at the end of Group Settings. Both ask first.
    func deleteGroupRow(_ row: XCUIElement) {
        row.swipeLeft()
        let delete = buttons["Delete"].firstMatch
        let settings = buttons["Group Settings"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3) || settings.exists, "The swipe shows an action")
        if delete.exists {
            delete.tap()
            confirmDestinationDelete()
            return
        }
        settings.tap()
        let deleteGroup = buttons["deleteGroupButton"].firstMatch
        XCTAssertTrue(deleteGroup.waitForExistence(timeout: 3))
        deleteGroup.tap()
        let confirm = alerts.firstMatch.buttons["confirmDeleteGroupButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Deleting a group asks first")
        confirm.tap()
    }
}
