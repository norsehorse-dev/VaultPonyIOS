import XCTest
@testable import VaultPony

/// Fixture corpus is the spec (PLAN.md section 9). Bundled into the test
/// target as a folder-reference resource (project.yml) so lookup works
/// identically on Simulator and device — no host filesystem access
/// assumed. Run ./scripts/fetch-fixtures.sh before `xcodegen generate` if
/// fixtures/ is empty; these skip loudly rather than fail when a fixture
/// can't be found, matching the core's own test convention.
final class FixtureTests: XCTestCase {
    private func fixtureURL(_ name: String) -> URL? {
        let bundle = Bundle(for: FixtureTests.self)
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: nil, subdirectory: "fixtures"),
            bundle.url(forResource: name, withExtension: nil),
            bundle.resourceURL?.appendingPathComponent("fixtures").appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func fixtureFd(_ name: String) -> Int32? {
        guard let url = fixtureURL(name) else { return nil }
        let fd = open(url.path, O_RDONLY)
        return fd >= 0 ? fd : nil
    }

    /// Bundle resources are read-only at runtime — copies the fixture to a
    /// writable temp location and returns an fd opened O_RDWR on the copy.
    private func writableFixtureFd(_ name: String) throws -> (fd: Int32, path: String)? {
        guard let sourceURL = fixtureURL(name) else { return nil }
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vc")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        let fd = open(destURL.path, O_RDWR)
        guard fd >= 0 else { return nil }
        return (fd, destURL.path)
    }

    func testUnlockBrowseReadLockThroughSwiftBindings() throws {
        guard let fd = fixtureFd("aes-sha_512-fat-512-pim0-plain.vc") else {
            throw XCTSkip("fixture not found in test bundle — run ./scripts/fetch-fixtures.sh then xcodegen generate")
        }
        let session = try VaultSession.unlockFd(fd: fd, passphrase: "vaultpony-fixture", pim: 0, keyfiles: [], kdf: .auto, cancel: nil, listener: nil)

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
            _ = try VaultSession.unlockFd(fd: fd, passphrase: "nope", pim: 0, keyfiles: [], kdf: .auto, cancel: nil, listener: nil)
            XCTFail("wrong password should not unlock")
        } catch VaultError.NotFoundOrWrongPassword {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// P2: write, flush, lock, then reopen with a NEW fd on the same file
    /// to prove the write reached disk — not just in-session state.
    func testWriteRoundTripPersistsToDisk() throws {
        guard let (fd, path) = try writableFixtureFd("aes-sha_512-fat-512-pim0-plain.vc") else {
            throw XCTSkip("fixture not found in test bundle — run ./scripts/fetch-fixtures.sh then xcodegen generate")
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        let session = try VaultSession.unlockFd(fd: fd, passphrase: "vaultpony-fixture", pim: 0, keyfiles: [], kdf: .auto, cancel: nil, listener: nil)
        try session.create(path: "/roundtrip.txt")
        let payload = "VaultPony P2 round-trip\n".data(using: .utf8)!
        _ = try session.writeAt(path: "/roundtrip.txt", offset: 0, data: payload)
        try session.flush()
        session.lock()

        // Fresh fd, fresh session — proves the bytes are on disk, not just
        // held in the session we just wrote through.
        let reopenFd = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(reopenFd, 0)
        let reopened = try VaultSession.unlockFd(fd: reopenFd, passphrase: "vaultpony-fixture", pim: 0, keyfiles: [], kdf: .auto, cancel: nil, listener: nil)

        let names = try reopened.list(path: "/").map(\.name)
        XCTAssertTrue(names.contains("roundtrip.txt"))

        let readBack = try reopened.readAt(path: "/roundtrip.txt", offset: 0, len: 1024)
        XCTAssertEqual(readBack, payload)

        // Original file (readme.txt) still intact — write didn't clobber
        // unrelated data.
        let readme = try reopened.readAt(path: "/readme.txt", offset: 0, len: 1024)
        XCTAssertEqual(readme, "VaultPony fixture tree v1\n".data(using: .utf8))

        reopened.lock()
    }
}
