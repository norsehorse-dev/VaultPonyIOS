import Foundation

// Bulk import planning (2.0.0, issue #3): FAT/exFAT name sanitizing,
// keep-both naming, collision handling and the free-space pre-flight.
// Plain Foundation, no UIKit and no core calls, so it is unit-tested
// directly (TransferPlannerTests). BulkTransfer.swift runs the plan.

/// What to do with a file whose name already exists in the vault folder.
/// Asked once per batch, before anything is copied.
enum CollisionPolicy: CaseIterable, Sendable {
    case keepBoth
    case skip
    case replace
}

/// One thing to import, as the walk of the picked files/folders found it.
/// `components` is the path relative to the destination folder, in the
/// source's own spelling; the last component is the item's own name.
/// Items come in pre-order: a folder before anything inside it.
struct TransferItem: Equatable, Sendable {
    var components: [String]
    var isDirectory: Bool
    var size: UInt64

    init(_ components: [String], isDirectory: Bool = false, size: UInt64 = 0) {
        self.components = components
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// A name that is already in a vault folder before the batch starts.
struct ExistingEntry: Equatable, Sendable {
    var name: String
    var isDirectory: Bool
}

/// A folder the import has to create (merged folders are not listed).
struct PlannedDirectory: Equatable, Sendable {
    var sourceIndex: Int
    var destPath: String
}

/// A file the import will copy. `replacesExisting` means a file of that
/// name is already there and the user chose Replace.
struct PlannedFile: Equatable, Sendable {
    var sourceIndex: Int
    var destPath: String
    var size: UInt64
    var replacesExisting: Bool
}

struct TransferPlan: Equatable, Sendable {
    /// New folders, parents first.
    var directories: [PlannedDirectory] = []
    var files: [PlannedFile] = []
    /// Vault folders that existed before the batch and receive files (the
    /// destination and every folder merged into). Leftover partial files
    /// from an interrupted import are cleaned out of these first.
    var existingFolders: [String] = []
    /// Names that already exist in the vault folder (file or folder).
    /// Folders merged into an existing folder don't count. This is what
    /// the "Some files already exist" prompt is about.
    var collisionCount = 0
    /// Files over the filesystem's per-file limit (FAT). Always skipped.
    var tooLargeCount = 0
    /// Files left out because the user chose Skip, including every file
    /// inside a skipped folder.
    var skippedExistingCount = 0
    /// Files and folders renamed to fit FAT/exFAT naming rules.
    var renamedCount = 0
    /// Files and folders given a "name (1)" style name so both are kept.
    var keptBothCount = 0
    /// Space the import takes: every file rounded up to whole clusters,
    /// plus one cluster per new folder.
    var bytesNeeded: UInt64 = 0

    var totalFileBytes: UInt64 { files.reduce(0) { $0 + $1.size } }

    func fits(freeBytes: UInt64) -> Bool { bytesNeeded <= freeBytes }
}

enum TransferNaming {
    /// FAT long names and exFAT names both stop at 255 UTF-16 units.
    static let maxNameUTF16 = 255

    private static let illegal: Set<Unicode.Scalar> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]

    /// Makes `name` storable on FAT/exFAT: each of \ / : * ? " < > | and
    /// control characters 0x00-0x1F becomes "_", trailing dots and spaces
    /// go, the name is capped at 255 UTF-16 units keeping its extension,
    /// and an empty result becomes "_".
    static func sanitize(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || illegal.contains(scalar) {
                scalars.append("_")
            } else {
                scalars.append(scalar)
            }
        }
        var result = stripTrailingDotsAndSpaces(String(scalars))
        result = stripTrailingDotsAndSpaces(capLength(result))
        return result.isEmpty ? "_" : result
    }

    /// Splits off the extension, dot included. Dotfiles (".bashrc") and
    /// names without a dot have none.
    static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// Prefix and suffix of the temporary name an import writes under
    /// before renaming the finished file into place.
    static let partialPrefix = ".vaultpony-"
    static let partialSuffix = ".part"

    /// A leftover from an import that never finished (the app was killed
    /// mid-file). Ignored when planning; the next import into that folder
    /// deletes it.
    static func isPartialName(_ name: String) -> Bool {
        name.hasPrefix(partialPrefix) && name.hasSuffix(partialSuffix)
    }

    /// The first of "name (1).ext", "name (2).ext", ... that `isTaken`
    /// rejects. Folders, dotfiles and names without an extension get
    /// "name (1)". The base is shortened when needed so the result stays
    /// within 255 UTF-16 units.
    static func keepBothName(for name: String, isDirectory: Bool = false, isTaken: (String) -> Bool) -> String {
        let (base, ext) = isDirectory ? (name, "") : splitExtension(name)
        var n = 1
        while true {
            let suffix = " (\(n))"
            let room = max(maxNameUTF16 - suffix.utf16.count - ext.utf16.count, 0)
            let candidate = truncate(base, toUTF16: room) + suffix + ext
            if !isTaken(candidate) {
                return candidate
            }
            n += 1
        }
    }

    /// FAT and exFAT compare names without regard to case.
    static func fold(_ name: String) -> String {
        name.lowercased()
    }

    /// `size` rounded up to whole clusters. An empty file takes none.
    static func onDisk(_ size: UInt64, clusterBytes: UInt64) -> UInt64 {
        guard clusterBytes > 0 else { return size }
        let (q, r) = size.quotientAndRemainder(dividingBy: clusterBytes)
        return (r == 0 ? q : q + 1) * clusterBytes
    }

    static func capLength(_ name: String, limit: Int = maxNameUTF16) -> String {
        guard name.utf16.count > limit else { return name }
        let (base, ext) = splitExtension(name)
        // A "extension" this long is really part of the name.
        guard ext.utf16.count < limit else { return truncate(name, toUTF16: limit) }
        return truncate(base, toUTF16: limit - ext.utf16.count) + ext
    }

    /// Cuts at a character boundary, so a surrogate pair or a combined
    /// character is never split.
    static func truncate(_ s: String, toUTF16 limit: Int) -> String {
        guard s.utf16.count > limit else { return s }
        var result = ""
        var used = 0
        for ch in s {
            let n = ch.utf16.count
            if used + n > limit { break }
            result.append(ch)
            used += n
        }
        return result
    }

    private static func stripTrailingDotsAndSpaces(_ s: String) -> String {
        var s = s
        while let last = s.last, last == "." || last == " " {
            s.removeLast()
        }
        return s
    }
}

enum TransferPlanner {
    /// Plans copying `items` into the vault folder `destination`.
    ///
    /// `existing` lists a vault folder that was there before the batch
    /// (the destination itself, and any folder an imported folder merges
    /// into). It is only called for those. Leftover partial files
    /// (`TransferNaming.isPartialName`) in those listings are ignored.
    ///
    /// Any name that is already there is a collision, whatever the kinds,
    /// except a folder meeting a folder, which is merged into. Skip leaves
    /// the item out (a skipped folder takes everything inside it along).
    /// Replace only applies file over file; a file meeting a folder or a
    /// folder meeting a file falls back to keep both, so nothing is ever
    /// removed to make room for a different kind of entry. This matches
    /// Android and Desktop.
    static func plan(
        items: [TransferItem],
        into destination: String,
        policy: CollisionPolicy,
        maxFileBytes: UInt64?,
        clusterBytes: UInt64,
        existing: (String) -> [ExistingEntry]
    ) -> TransferPlan {
        var plan = TransferPlan()

        struct Folder {
            /// Folded name -> what was already there.
            var existing: [String: ExistingEntry]
            /// Folded names this batch has used.
            var assigned: Set<String> = []

            func isTaken(_ name: String) -> Bool {
                let key = TransferNaming.fold(name)
                return existing[key] != nil || assigned.contains(key)
            }
        }

        func listed(_ path: String) -> Folder {
            plan.existingFolders.append(path)
            let entries = existing(path).filter { !TransferNaming.isPartialName($0.name) }
            return Folder(existing: Dictionary(entries.map { (TransferNaming.fold($0.name), $0) }, uniquingKeysWith: { first, _ in first }))
        }

        var folders: [String: Folder] = [destination: listed(destination)]
        // Source folder (components) -> vault path it lands at.
        var resolved: [[String]: String] = [[]: destination]
        // Source folders left out by Skip; everything inside goes too.
        var skippedFolders: Set<[String]> = []

        for (i, item) in items.enumerated() {
            guard let raw = item.components.last else { continue }
            let parentKey = Array(item.components.dropLast())
            if skippedFolders.contains(parentKey) {
                if item.isDirectory {
                    skippedFolders.insert(item.components)
                } else {
                    plan.skippedExistingCount += 1
                }
                continue
            }
            guard let parent = resolved[parentKey], var folder = folders[parent] else { continue }

            if !item.isDirectory, let limit = maxFileBytes, item.size > limit {
                plan.tooLargeCount += 1
                continue
            }

            let clean = TransferNaming.sanitize(raw)
            if clean != raw { plan.renamedCount += 1 }
            let key = TransferNaming.fold(clean)

            var name = clean
            var replaces = false
            var mergePath: String?
            if folder.assigned.contains(key) {
                // Two items in this batch end up with the same name (case,
                // or sanitizing).
                name = TransferNaming.keepBothName(for: clean, isDirectory: item.isDirectory, isTaken: folder.isTaken)
                plan.keptBothCount += 1
            } else if let there = folder.existing[key] {
                if item.isDirectory && there.isDirectory {
                    name = there.name
                    mergePath = join(parent, there.name)
                } else {
                    plan.collisionCount += 1
                    if policy == .skip {
                        if item.isDirectory {
                            skippedFolders.insert(item.components)
                        } else {
                            plan.skippedExistingCount += 1
                        }
                        continue
                    } else if policy == .replace && !item.isDirectory && !there.isDirectory {
                        name = there.name
                        replaces = true
                    } else {
                        name = TransferNaming.keepBothName(for: clean, isDirectory: item.isDirectory, isTaken: folder.isTaken)
                        plan.keptBothCount += 1
                    }
                }
            }

            folder.assigned.insert(TransferNaming.fold(name))
            folders[parent] = folder
            let path = join(parent, name)

            if item.isDirectory {
                resolved[item.components] = path
                if let mergePath {
                    if folders[mergePath] == nil {
                        folders[mergePath] = listed(mergePath)
                    }
                } else {
                    folders[path] = Folder(existing: [:])
                    plan.directories.append(PlannedDirectory(sourceIndex: i, destPath: path))
                    plan.bytesNeeded += clusterBytes
                }
            } else {
                plan.bytesNeeded += TransferNaming.onDisk(item.size, clusterBytes: clusterBytes)
                plan.files.append(PlannedFile(sourceIndex: i, destPath: path, size: item.size, replacesExisting: replaces))
            }
        }
        return plan
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/\(name)" : "\(folder)/\(name)"
    }
}
