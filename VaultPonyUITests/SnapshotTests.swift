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

        XCTAssertTrue(app.staticTexts["Demo Vault"].waitForExistence(timeout: 15))
        snapshot("01Home")

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        snapshot("02Settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.staticTexts["Demo Vault"].waitForExistence(timeout: 5))
        app.staticTexts["Demo Vault"].tap()

        let passwordField = app.secureTextFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.tap()
        passwordField.typeText(demoPassphrase)
        app.buttons["Unlock"].tap()

        XCTAssertTrue(app.staticTexts["Welcome.txt"].waitForExistence(timeout: 15))
        snapshot("03Browse")

        app.staticTexts["Welcome.txt"].tap()
        XCTAssertTrue(app.navigationBars["Welcome.txt"].waitForExistence(timeout: 10))
        snapshot("04Viewer")
    }
}
