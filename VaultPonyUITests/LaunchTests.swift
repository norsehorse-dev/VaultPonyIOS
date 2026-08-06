import XCTest

final class LaunchTests: XCTestCase {
    /// P0 gate: app launches and shows Home. Onboarding-gated as of P7's
    /// onboarding carousel (OnboardingView.swift) — every fresh install
    /// lands there first, so skip it before checking for Home.
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        let skipButton = app.buttons["onboardingSkipButton"]
        if skipButton.waitForExistence(timeout: 5) {
            skipButton.tap()
        }
        XCTAssertTrue(app.staticTexts["VaultPony"].waitForExistence(timeout: 5))
    }
}
