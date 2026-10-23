import Foundation

// Browser upgrades (2.0.0 rc4, plan 5.3): sorting, search and the
// multi-select operations, kept apart from BrowserView's layout.

enum SearchScope: Hashable {
    case thisFolder
    case wholeVault
}

/// A whole-vault search match.
struct SearchHit: Identifiable, Hashable {
    let path: String
    let name: String
    let isDir: Bool
    let size: UInt64

    var id: String { path }
    var folder: String { VaultPath.parent(path) }
}

enum BrowserSorting {
    /// Folders first, always; then by `sort`, ties by name.
    static func sorted(_ entries: [DirEntry], by sort: BrowserSort, ascending: Bool) -> [DirEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDir != rhs.isDir {
                return lhs.isDir
            }
            let order: ComparisonResult
            switch sort {
            case .name:
                order = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                order = compare(lhs.size, rhs.size)
            case .dateModified:
                // No date (NTFS stat, some FAT entries) sorts as oldest.
                order = compare(lhs.mtimeMs ?? .min, rhs.mtimeMs ?? .min)
            }
            if order == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    /// Case-insensitive "name contains".
    static func matches(_ name: String, _ query: String) -> Bool {
        name.range(of: query, options: .caseInsensitive) != nil
    }
}

enum VaultSearch {
    /// Walks the whole vault breadth first and reports the matches found so
    /// far after each folder. Stops when the task is cancelled or `isOpen`
    /// says the session was locked. Hidden temp names are never listed.
    static func walk(
        session: VaultSession,
        query: String,
        isOpen: @MainActor () -> Bool,
        report: @MainActor ([SearchHit]) -> Void
    ) async {
        var queue = ["/"]
        var hits: [SearchHit] = []
        var reported = 0
        while !queue.isEmpty {
            if Task.isCancelled { return }
            guard await isOpen() else { return }
            let folder = queue.removeFirst()
            guard let entries = try? await Vault.list(session, path: folder) else { continue }
            for entry in entries where entry.name != "." && entry.name != ".." && !FilesNaming.isHiddenFromListing(entry.name) {
                let path = VaultPath.join(folder, entry.name)
                if entry.isDir {
                    queue.append(path)
                }
                if BrowserSorting.matches(entry.name, query) {
                    hits.append(SearchHit(path: path, name: entry.name, isDir: entry.isDir, size: entry.size))
                }
            }
            if hits.count != reported, !Task.isCancelled {
                reported = hits.count
                await report(hits)
            }
        }
    }
}

enum VaultTreeOps {
    /// Deletes a file, or a folder with everything in it (temp files
    /// included, or the folder couldn't go).
    static func removeTree(_ session: VaultSession, path: String, isDir: Bool) async throws {
        if isDir {
            for child in try await Vault.list(session, path: path) where child.name != "." && child.name != ".." {
                try await removeTree(session, path: VaultPath.join(path, child.name), isDir: child.isDir)
            }
        }
        try await Vault.remove(session, path: path)
    }

    /// Moves `items` (names in `folder`) into `destination`. A name already
    /// there gets "name (1)" (D6). Folders are never moved into themselves;
    /// the picker doesn't offer that, and this skips it too.
    static func move(_ session: VaultSession, items: [DirEntry], from folder: String, to destination: String) async throws {
        guard destination != folder else { return }
        let existing = try await Vault.list(session, path: destination)
        var taken = Set(existing.map { TransferNaming.fold($0.name) })
        for item in items {
            let source = VaultPath.join(folder, item.name)
            if item.isDir, destination == source || destination.hasPrefix(source + "/") {
                continue
            }
            var name = item.name
            if taken.contains(TransferNaming.fold(name)) {
                name = TransferNaming.keepBothName(for: name, isDirectory: item.isDir) { taken.contains(TransferNaming.fold($0)) }
            }
            try await Vault.rename(session, from: source, to: VaultPath.join(destination, name))
            taken.insert(TransferNaming.fold(name))
        }
    }
}
