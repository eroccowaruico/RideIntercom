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

    /// Reopens the current call from the accessory above the tab bar, or the Current Call row.
    func openCurrentCall() {
        if buttons["closeCallButton"].firstMatch.exists { return }
        let accessory = buttons["callAccessoryOpenButton"].firstMatch
        if accessory.waitForExistence(timeout: 3) { accessory.tap(); return }
        let current = buttons["standardCurrentCallButton"].firstMatch
        if current.waitForExistence(timeout: 3) { current.tap() }
    }
}
