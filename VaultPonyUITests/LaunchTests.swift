import XCTest

final class LaunchTests: XCTestCase {
    /// P0 gate: app launches and shows the walking-skeleton screen.
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["VaultPony"].waitForExistence(timeout: 5))
    }
}
