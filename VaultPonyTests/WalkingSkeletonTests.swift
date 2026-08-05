import XCTest
@testable import VaultPony

final class WalkingSkeletonTests: XCTestCase {
    /// P0 gate: proves the test target links against VaultFFI too.
    func testCoreVersionIsNonEmpty() {
        XCTAssertFalse(coreVersion().isEmpty)
    }
}
