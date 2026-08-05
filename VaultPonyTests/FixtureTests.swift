import XCTest
@testable import VaultPony

/// Fixture corpus is the spec (PLAN.md section 9). Bundled into the test
/// target as a folder-reference resource (project.yml) so lookup works
/// identically on Simulator and device — no host filesystem access
/// assumed. Run ./scripts/fetch-fixtures.sh before `xcodegen generate` if
/// fixtures/ is empty; these skip loudly rather than fail when a fixture
/// can't be found, matching the core's own test convention.
final class FixtureTests: XCTestCase {
    private func fixtureFd(_ name: String) -> Int32? {
        let bundle = Bundle(for: FixtureTests.self)
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: nil, subdirectory: "fixtures"),
            bundle.url(forResource: name, withExtension: nil),
            bundle.resourceURL?.appendingPathComponent("fixtures").appendingPathComponent(name),
        ]
        for case let url? in candidates {
            let fd = open(url.path, O_RDONLY)
            if fd >= 0 { return fd }
        }
        return nil
    }

    func testUnlockBrowseReadLockThroughSwiftBindings() throws {
        guard let fd = fixtureFd("aes-sha_512-fat-512-pim0-plain.vc") else {
            throw XCTSkip("fixture not found in test bundle — run ./scripts/fetch-fixtures.sh then xcodegen generate")
        }
        let session = try VaultSession.unlockFd(fd: fd, passphrase: "vaultpony-fixture", pim: 0, keyfiles: [], listener: nil)

        let facts = try session.facts()
        XCTAssertEqual(facts.scheme, "AES")
        XCTAssertEqual(facts.filesystem, "Fat")

        let names = try session.list(path: "/").map(\.name)
        XCTAssertTrue(names.contains("readme.txt"))

        let data = try session.readAt(path: "/readme.txt", offset: 0, len: 1024)
        XCTAssertEqual(data, "VaultPony fixture tree v1\n".data(using: .utf8))

        let tail = try session.readAt(path: "/readme.txt", offset: 10, len: 1024)
        XCTAssertEqual(tail, "fixture tree v1\n".data(using: .utf8))

        session.lock()
        session.lock() // idempotent

        do {
            _ = try session.list(path: "/")
            XCTFail("expected .Internal after lock")
        } catch VaultError.Internal {
            // expected
        } catch {
            XCTFail("expected .Internal after lock, got \(error)")
        }
    }

    func testWrongPasswordMapsToTheRightError() throws {
        guard let fd = fixtureFd("aes-sha_512-fat-512-pim0-plain.vc") else {
            throw XCTSkip("fixture not found in test bundle — run ./scripts/fetch-fixtures.sh then xcodegen generate")
        }
        do {
            _ = try VaultSession.unlockFd(fd: fd, passphrase: "nope", pim: 0, keyfiles: [], listener: nil)
            XCTFail("wrong password should not unlock")
        } catch VaultError.NotFoundOrWrongPassword {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
