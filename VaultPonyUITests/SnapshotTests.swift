import XCTest

/// Drives the app through Home, Settings, a populated Browser, and the
/// Viewer to capture App Store screenshots (P7). Actually *run* via
/// `fastlane snapshot` (the `VaultPonySnapshots` scheme, filtered to this
/// test) -- it's still compiled as part of the plain `VaultPony` scheme's
/// build-for-testing phase like every file in this target, it just isn't
/// in that scheme's executed test list, so `xcodebuild test` on `VaultPony`
/// never runs it.
///
/// UI test targets are a separate process from the app under test and
/// don't link against its module, so this can't import `DemoSeed`
/// directly -- `demoPassphrase` below must be kept in sync by hand with
/// `VaultPony/App/DemoSeed.swift`'s `passphrase` constant.
final class SnapshotTests: XCTestCase {
    private let demoPassphrase = "DemoPassword123!"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // SnapshotHelper's setupSnapshot/snapshot are @MainActor in this
    // fastlane version; XCTestCase test methods aren't MainActor by
    // default, so calling them synchronously needs this annotation.
    @MainActor
    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["-seedDemoVault"]
        app.launch()

        // Every fresh install lands on the onboarding carousel (P7 parity
        // port of VaultPonyAndroid's OnboardingScreen) before Home ever
        // appears. Skip it here — the onboarding carousel itself isn't
        // part of this screenshot set.
        let skipButton = app.buttons["onboardingSkipButton"]
        XCTAssertTrue(skipButton.waitForExistence(timeout: 10))
        skipButton.tap()

        // "Demo Vault" / "Welcome.txt" are DemoSeed's own literal data
        // strings, never routed through the string catalog, so they read
        // the same in every locale. UI chrome (button/field labels, nav
        // titles) IS localized as of P6 -- those elements are looked up
        // by accessibilityIdentifier instead, which stays constant
        // across languages.
        XCTAssertTrue(app.staticTexts["Demo Vault"].waitForExistence(timeout: 15))
        snapshot("01Home")

        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settingsScreen"].waitForExistence(timeout: 5))
        snapshot("02Settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.staticTexts["Demo Vault"].waitForExistence(timeout: 5))
        app.staticTexts["Demo Vault"].tap()

        let passwordField = app.secureTextFields["passwordField"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.tap()
        passwordField.typeText(demoPassphrase)
        app.buttons["unlockButton"].tap()

        XCTAssertTrue(app.staticTexts["Welcome.txt"].waitForExistence(timeout: 15))
        snapshot("03Browse")

        app.staticTexts["Welcome.txt"].tap()
        XCTAssertTrue(app.navigationBars["Welcome.txt"].waitForExistence(timeout: 10))
        snapshot("04Viewer")
    }
}
