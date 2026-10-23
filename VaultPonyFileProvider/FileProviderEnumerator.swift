import FileProvider

/// Lists one vault folder. Changes are reported by expiring the sync anchor
/// whenever the vault's generation moved, so Files simply lists again.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let vault: FilesVault
    private let folder: String
    private static let pageSize = 500

    init(vault: FilesVault, folder: String) {
        self.vault = vault
        self.folder = folder
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            let (_, codec) = try vault.open()
            let entries = try vault.list(folder).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let start = Self.offset(of: page)
            let end = min(start + Self.pageSize, entries.count)
            let writable = vault.isWritable
            let items: [NSFileProviderItem] = start < end
                ? entries[start..<end].map {
                    FileProviderItem(path: VaultPath.join(folder, $0.name), entry: $0, codec: codec, writable: writable)
                }
                : []
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: end < entries.count ? Self.page(for: end) : nil)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        guard vault.isOpen else {
            observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
            return
        }
        let current = anchor()
        if current.rawValue == syncAnchor.rawValue {
            observer.finishEnumeratingChanges(upTo: current, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchor())
    }

    /// Changes whenever the volume changed or turned read-only (item
    /// capabilities then change too).
    private func anchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(FilesGate.shared.generation())-\(vault.isWritable ? 1 : 0)".utf8))
    }

    /// Our continuation pages are "VP" plus a little-endian offset; anything
    /// else (the system's initial pages) starts at the top.
    private static func offset(of page: NSFileProviderPage) -> Int {
        let data = page.rawValue
        guard data.count == 10, data.prefix(2) == Data("VP".utf8) else { return 0 }
        let value = data.dropFirst(2).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        return Int(clamping: value)
    }

    private static func page(for offset: Int) -> NSFileProviderPage {
        var data = Data("VP".utf8)
        let v = UInt64(offset)
        for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
        return NSFileProviderPage(data)
    }
}

/// The working set feeds Recents, tags and Spotlight. VaultPony's is always
/// empty (D20).
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.didEnumerate([])
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: syncAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data([0])))
    }
}
