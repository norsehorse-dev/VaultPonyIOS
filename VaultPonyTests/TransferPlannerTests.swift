import XCTest
@testable import VaultPony

/// Bulk import planning (TransferPlanner.swift): names, collisions and the
/// space pre-flight. Pure logic, no vault needed.
final class TransferPlannerTests: XCTestCase {
    private let cluster: UInt64 = 4096
    private let fatLimit: UInt64 = 4_294_967_295

    // MARK: - Sanitizing

    func testSanitizeReplacesCharactersFatCannotStore() {
        XCTAssertEqual(TransferNaming.sanitize("a:b*c?.txt"), "a_b_c_.txt")
        XCTAssertEqual(TransferNaming.sanitize("x\\y/z\"<>|.md"), "x_y_z____.md")
        XCTAssertEqual(TransferNaming.sanitize("tab\there\u{1}.txt"), "tab_here_.txt")
    }

    func testSanitizeStripsTrailingDotsAndSpaces() {
        XCTAssertEqual(TransferNaming.sanitize("notes. . "), "notes")
        XCTAssertEqual(TransferNaming.sanitize("report.pdf  "), "report.pdf")
    }

    func testSanitizeEmptyBecomesUnderscore() {
        XCTAssertEqual(TransferNaming.sanitize(""), "_")
        XCTAssertEqual(TransferNaming.sanitize("..."), "_")
        XCTAssertEqual(TransferNaming.sanitize("   "), "_")
    }

    func testSanitizeLeavesLegalNamesAlone() {
        for name in ["photo.jpg", ".bashrc", "Ünïcödé 日本.txt", "a (1).txt"] {
            XCTAssertEqual(TransferNaming.sanitize(name), name)
        }
    }

    func testSanitizeCapsLengthKeepingExtension() {
        let long = String(repeating: "a", count: 300) + ".jpg"
        let capped = TransferNaming.sanitize(long)
        XCTAssertEqual(capped.utf16.count, 255)
        XCTAssertTrue(capped.hasSuffix(".jpg"))
    }

    func testCapNeverSplitsASurrogatePair() {
        // Each emoji is two UTF-16 units; 254 units of base leave no room
        // for half of one.
        let long = String(repeating: "😀", count: 200) + ".txt"
        let capped = TransferNaming.sanitize(long)
        XCTAssertLessThanOrEqual(capped.utf16.count, 255)
        XCTAssertTrue(capped.hasSuffix(".txt"))
        XCTAssertEqual(capped.dropLast(4).count, (255 - 4) / 2)
    }

    // MARK: - Keep-both names

    func testKeepBothAddsNumberBeforeExtension() {
        let taken: Set<String> = ["photo.jpg"]
        XCTAssertEqual(TransferNaming.keepBothName(for: "photo.jpg") { taken.contains($0) }, "photo (1).jpg")
    }

    func testKeepBothCountsUpUntilFree() {
        let taken: Set<String> = ["photo.jpg", "photo (1).jpg", "photo (2).jpg"]
        XCTAssertEqual(TransferNaming.keepBothName(for: "photo.jpg") { taken.contains($0) }, "photo (3).jpg")
    }

    func testKeepBothDotfilesAndNoExtension() {
        XCTAssertEqual(TransferNaming.keepBothName(for: ".bashrc") { $0 == ".bashrc" }, ".bashrc (1)")
        XCTAssertEqual(TransferNaming.keepBothName(for: "README") { $0 == "README" }, "README (1)")
        XCTAssertEqual(TransferNaming.keepBothName(for: "archive.tar.gz") { $0 == "archive.tar.gz" }, "archive.tar (1).gz")
    }

    func testKeepBothStaysWithinNameLimit() {
        let long = String(repeating: "b", count: 251) + ".txt"
        let name = TransferNaming.keepBothName(for: long) { $0 == long }
        XCTAssertEqual(name.utf16.count, 255)
        XCTAssertTrue(name.hasSuffix(" (1).txt"))
    }

    // MARK: - Space math

    func testOnDiskRoundsUpToClusters() {
        XCTAssertEqual(TransferNaming.onDisk(0, clusterBytes: cluster), 0)
        XCTAssertEqual(TransferNaming.onDisk(1, clusterBytes: cluster), 4096)
        XCTAssertEqual(TransferNaming.onDisk(4096, clusterBytes: cluster), 4096)
        XCTAssertEqual(TransferNaming.onDisk(4097, clusterBytes: cluster), 8192)
        XCTAssertEqual(TransferNaming.onDisk(10, clusterBytes: 0), 10)
    }

    func testBytesNeededCountsFilesAndNewFolders() {
        let items = [
            TransferItem(["Album"], isDirectory: true),
            TransferItem(["Album", "a.jpg"], size: 5000),
            TransferItem(["Album", "Empty"], isDirectory: true),
            TransferItem(["b.txt"], size: 10),
        ]
        let plan = makePlan(items)
        // a.jpg: 2 clusters, b.txt: 1, two new folders: 2.
        XCTAssertEqual(plan.bytesNeeded, 5 * cluster)
        XCTAssertTrue(plan.fits(freeBytes: 5 * cluster))
        XCTAssertFalse(plan.fits(freeBytes: 5 * cluster - 1))
        XCTAssertEqual(plan.directories.map(\.destPath), ["/Album", "/Album/Empty"])
        XCTAssertEqual(plan.files.map(\.destPath), ["/Album/a.jpg", "/b.txt"])
    }

    // MARK: - Planning

    func testNoCollisionsCopiesEverythingAsIs() {
        let plan = makePlan([TransferItem(["a.txt"], size: 1), TransferItem(["b.txt"], size: 1)], into: "/Docs")
        XCTAssertEqual(plan.collisionCount, 0)
        XCTAssertEqual(plan.files.map(\.destPath), ["/Docs/a.txt", "/Docs/b.txt"])
    }

    func testKeepBothRenamesCollidingFiles() {
        let plan = makePlan([TransferItem(["a.txt"], size: 1), TransferItem(["b.txt"], size: 1)],
                            existing: ["/": [ExistingEntry(name: "a.txt", isDirectory: false)]])
        XCTAssertEqual(plan.collisionCount, 1)
        XCTAssertEqual(plan.keptBothCount, 1)
        XCTAssertEqual(plan.files.map(\.destPath), ["/a (1).txt", "/b.txt"])
        XCTAssertFalse(plan.files[0].replacesExisting)
    }

    func testCollisionsIgnoreCase() {
        let plan = makePlan([TransferItem(["Photo.JPG"], size: 1)],
                            existing: ["/": [ExistingEntry(name: "photo.jpg", isDirectory: false)]])
        XCTAssertEqual(plan.collisionCount, 1)
        XCTAssertEqual(plan.files.map(\.destPath), ["/Photo (1).JPG"])
    }

    func testSkipLeavesCollidingFilesOut() {
        let plan = makePlan([TransferItem(["a.txt"], size: 1), TransferItem(["b.txt"], size: 1)],
                            policy: .skip,
                            existing: ["/": [ExistingEntry(name: "a.txt", isDirectory: false)]])
        XCTAssertEqual(plan.skippedExistingCount, 1)
        XCTAssertEqual(plan.files.map(\.destPath), ["/b.txt"])
        XCTAssertEqual(plan.bytesNeeded, cluster)
    }

    func testReplaceTargetsTheExistingName() {
        let plan = makePlan([TransferItem(["A.txt"], size: 1)],
                            policy: .replace,
                            existing: ["/": [ExistingEntry(name: "a.txt", isDirectory: false)]])
        XCTAssertEqual(plan.files.map(\.destPath), ["/a.txt"])
        XCTAssertTrue(plan.files[0].replacesExisting)
        XCTAssertEqual(plan.keptBothCount, 0)
    }

    func testExistingFolderIsMergedNotRenamed() {
        let items = [
            TransferItem(["Album"], isDirectory: true),
            TransferItem(["Album", "a.jpg"], size: 1),
            TransferItem(["Album", "new.jpg"], size: 1),
        ]
        let plan = makePlan(items, existing: [
            "/": [ExistingEntry(name: "album", isDirectory: true)],
            "/album": [ExistingEntry(name: "a.jpg", isDirectory: false)],
        ])
        XCTAssertTrue(plan.directories.isEmpty, "merging creates no folder")
        XCTAssertEqual(plan.collisionCount, 1)
        XCTAssertEqual(plan.files.map(\.destPath), ["/album/a (1).jpg", "/album/new.jpg"])
        XCTAssertEqual(plan.bytesNeeded, 2 * cluster)
        XCTAssertEqual(plan.existingFolders, ["/", "/album"])
    }

    func testFolderOverAnExistingFileIsACollision() {
        let items = [TransferItem(["Album"], isDirectory: true), TransferItem(["Album", "a.jpg"], size: 1)]
        let plan = makePlan(items, existing: ["/": [ExistingEntry(name: "Album", isDirectory: false)]])
        XCTAssertEqual(plan.collisionCount, 1)
        XCTAssertEqual(plan.keptBothCount, 1)
        XCTAssertEqual(plan.directories.map(\.destPath), ["/Album (1)"])
        XCTAssertEqual(plan.files.map(\.destPath), ["/Album (1)/a.jpg"])
    }

    func testSkipLeavesOutAFolderOverAnExistingFileWithItsContents() {
        let items = [
            TransferItem(["Album"], isDirectory: true),
            TransferItem(["Album", "Sub"], isDirectory: true),
            TransferItem(["Album", "Sub", "a.jpg"], size: 1),
            TransferItem(["Album", "b.jpg"], size: 1),
            TransferItem(["c.jpg"], size: 1),
        ]
        let plan = makePlan(items, policy: .skip, existing: ["/": [ExistingEntry(name: "album", isDirectory: false)]])
        XCTAssertEqual(plan.collisionCount, 1)
        XCTAssertTrue(plan.directories.isEmpty)
        XCTAssertEqual(plan.files.map(\.destPath), ["/c.jpg"])
        XCTAssertEqual(plan.skippedExistingCount, 2, "both files inside the skipped folder")
    }

    func testReplaceNeverSwapsAFolderForAFile() {
        let items = [TransferItem(["Album"], isDirectory: true)]
        let plan = makePlan(items, policy: .replace, existing: ["/": [ExistingEntry(name: "Album", isDirectory: false)]])
        XCTAssertEqual(plan.collisionCount, 1)
        XCTAssertEqual(plan.directories.map(\.destPath), ["/Album (1)"])
    }

    func testFileOverAnExistingFolderIsACollisionButNeverReplaces() {
        let replace = makePlan([TransferItem(["Album"], size: 1)], policy: .replace,
                               existing: ["/": [ExistingEntry(name: "Album", isDirectory: true)]])
        XCTAssertEqual(replace.collisionCount, 1)
        XCTAssertEqual(replace.files.map(\.destPath), ["/Album (1)"])
        XCTAssertFalse(replace.files[0].replacesExisting)

        let skip = makePlan([TransferItem(["Album"], size: 1)], policy: .skip,
                            existing: ["/": [ExistingEntry(name: "Album", isDirectory: true)]])
        XCTAssertTrue(skip.files.isEmpty)
        XCTAssertEqual(skip.skippedExistingCount, 1)
    }

    func testFolderKeepBothDoesNotSplitAnExtension() {
        let items = [TransferItem(["my.photos"], isDirectory: true)]
        let plan = makePlan(items, existing: ["/": [ExistingEntry(name: "my.photos", isDirectory: false)]])
        XCTAssertEqual(plan.directories.map(\.destPath), ["/my.photos (1)"])
    }

    func testLeftoverPartialFilesAreIgnored() {
        let partial = ".vaultpony-1a2b3c4d.part"
        XCTAssertTrue(TransferNaming.isPartialName(partial))
        XCTAssertFalse(TransferNaming.isPartialName("notes.part"))
        XCTAssertFalse(TransferNaming.isPartialName(".vaultpony-config"))
        let plan = makePlan([TransferItem([partial], size: 1)],
                            existing: ["/": [ExistingEntry(name: partial, isDirectory: false)]])
        XCTAssertEqual(plan.collisionCount, 0)
        XCTAssertEqual(plan.files.map(\.destPath), ["/" + partial])
        XCTAssertEqual(plan.existingFolders, ["/"])
    }

    func testNamesThatMeetAfterSanitizingKeepBoth() {
        let plan = makePlan([TransferItem(["a:b.txt"], size: 1), TransferItem(["a_b.txt"], size: 1)])
        XCTAssertEqual(plan.renamedCount, 1)
        XCTAssertEqual(plan.keptBothCount, 1)
        XCTAssertEqual(plan.files.map(\.destPath), ["/a_b.txt", "/a_b (1).txt"])
        XCTAssertEqual(plan.collisionCount, 0, "a clash inside the batch is not a prompt")
    }

    func testFatSkipsFilesOverTheLimit() {
        let items = [TransferItem(["big.mkv"], size: fatLimit + 1), TransferItem(["ok.mkv"], size: fatLimit)]
        let fat = makePlan(items, maxFileBytes: fatLimit)
        XCTAssertEqual(fat.tooLargeCount, 1)
        XCTAssertEqual(fat.files.map(\.destPath), ["/ok.mkv"])

        let exfat = makePlan(items, maxFileBytes: nil)
        XCTAssertEqual(exfat.tooLargeCount, 0)
        XCTAssertEqual(exfat.files.count, 2)
    }

    func testRenamedFolderCarriesItsChildren() {
        let items = [TransferItem(["Q3: plan"], isDirectory: true), TransferItem(["Q3: plan", "x?.txt"], size: 1)]
        let plan = makePlan(items)
        XCTAssertEqual(plan.renamedCount, 2)
        XCTAssertEqual(plan.directories.map(\.destPath), ["/Q3_ plan"])
        XCTAssertEqual(plan.files.map(\.destPath), ["/Q3_ plan/x_.txt"])
    }

    // MARK: - Helpers

    private func makePlan(
        _ items: [TransferItem],
        into destination: String = "/",
        policy: CollisionPolicy = .keepBoth,
        maxFileBytes: UInt64? = nil,
        existing: [String: [ExistingEntry]] = [:]
    ) -> TransferPlan {
        TransferPlanner.plan(
            items: items,
            into: destination,
            policy: policy,
            maxFileBytes: maxFileBytes,
            clusterBytes: cluster,
            existing: { existing[$0] ?? [] }
        )
    }
}
