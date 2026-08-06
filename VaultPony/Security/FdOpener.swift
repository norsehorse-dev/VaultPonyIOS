import Foundation

/// PLAN.md section 5: opening files on iOS. Resolves a security-scoped
/// bookmark/URL to a raw, owned file descriptor for the core. The core
/// takes ownership of the fd it's handed and closes it — callers here
/// never close the fd themselves.
enum FdOpenError: LocalizedError {
    case bookmarkResolutionFailed
    case accessDenied
    case iCloudDownloadFailed
    case openFailed(errno: Int32)
    case noTraceCopyInDisabled

    var errorDescription: String? {
        let locale = LanguageOverride.locale
        switch self {
        case .bookmarkResolutionFailed:
            return String(localized: "Couldn't locate that file. It may have been moved or deleted.", locale: locale)
        case .accessDenied:
            return String(localized: "VaultPony doesn't have permission to open that file.", locale: locale)
        case .iCloudDownloadFailed:
            return String(localized: "Couldn't download the file from iCloud. Check your connection and try again.", locale: locale)
        case .openFailed(let code):
            return String(localized: "Couldn't open the file (error \(code)).", locale: locale)
        case .noTraceCopyInDisabled:
            return String(localized: "This vault's location doesn't support editing in place, and no-trace mode disables the copy-in fallback. Try a different storage location, or turn off no-trace mode in Settings.", locale: locale)
        }
    }
}

enum FdOpener {
    /// Resolves a previously-saved bookmark and opens it read-only or
    /// read-write. Returns a refreshed bookmark when the original had
    /// gone stale (PLAN.md section 6 — HomeView/VaultStore surface this).
    static func openForUnlock(bookmark: Data, writable: Bool = false) throws -> (fd: Int32, refreshedBookmark: Data?) {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw FdOpenError.bookmarkResolutionFailed
        }
        return try open(url: url, writable: writable, refreshBookmarkIfStale: isStale)
    }

    /// Resolves a fresh URL (from a document-picker pick) and returns the
    /// open fd plus a bookmark to persist.
    static func openForImport(url: URL, writable: Bool = false) throws -> (fd: Int32, bookmark: Data) {
        let (fd, refreshed) = try open(url: url, writable: writable, refreshBookmarkIfStale: true)
        guard let bookmark = refreshed else {
            throw FdOpenError.bookmarkResolutionFailed
        }
        return (fd, bookmark)
    }

    private static func open(url: URL, writable: Bool, refreshBookmarkIfStale: Bool) throws -> (fd: Int32, refreshedBookmark: Data?) {
        guard url.startAccessingSecurityScopedResource() else {
            throw FdOpenError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        try ensureDownloaded(url)

        var refreshed: Data? = nil
        if refreshBookmarkIfStale {
            refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }

        let fd = try openFd(url, writable: writable)
        return (fd, refreshed)
    }

    /// Downloads an iCloud-dataless file in place before we ever open(2)
    /// it — the core must never see an fd to a dataless file.
    private static func ensureDownloaded(_ url: URL) throws {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
            return
        }
        let status = values.ubiquitousItemDownloadingStatus
        if status == .current || status == .downloaded {
            return
        }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let current = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
               current == .current || current == .downloaded {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw FdOpenError.iCloudDownloadFailed
    }

    private static func openFd(_ url: URL, writable: Bool) throws -> Int32 {
        var coordinatorError: NSError?
        var openedFd: Int32 = -1
        var thrown: Error?

        let coordinator = NSFileCoordinator()
        let accessor: (URL) -> Void = { coordinatedURL in
            let flags = writable ? O_RDWR : O_RDONLY
            let fd = coordinatedURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, flags)
            }
            if fd < 0 {
                thrown = FdOpenError.openFailed(errno: errno)
            } else {
                openedFd = fd
            }
        }

        if writable {
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError, byAccessor: accessor)
        }

        if let coordinatorError { throw coordinatorError }
        if let thrown { throw thrown }
        guard openedFd >= 0 else { throw FdOpenError.openFailed(errno: -1) }
        return openedFd
    }

    // MARK: - P2: copy-in / write-back fallback
    //
    // Some storage providers (mainly third-party Files providers, and some
    // On My iPhone edge cases) hand back a read-only fd even when we ask
    // NSFileCoordinator to open for writing — there's no reliable way to
    // detect this ahead of time other than trying. When openForUnlock's
    // writable open fails, UnlockView falls back to this: copy the
    // container into our own sandbox, edit that copy, and offer to write
    // the result back through the coordinator (which *is* reliable for a
    // whole-file replace) when the vault is locked (PLAN.md section 5).
    // P5: UnlockView refuses to call this at all when no-trace mode is
    // on (FdOpenError.noTraceCopyInDisabled) — a decrypted-adjacent copy
    // sitting in app storage is exactly what no-trace promises not to do.

    /// Copies the bookmarked file into app storage and opens the copy
    /// read-write. Returns the fd (core-owned, as always) and the copy's
    /// path relative to `copiedVaultsDirectory()`, to be handed back to
    /// `writeBack(localCopyRelativePath:toBookmark:)` at lock time.
    static func openViaCopyIn(bookmark: Data) throws -> (fd: Int32, localCopyRelativePath: String) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard url.startAccessingSecurityScopedResource() else { throw FdOpenError.accessDenied }
        defer { url.stopAccessingSecurityScopedResource() }
        try ensureDownloaded(url)

        let dir = try copiedVaultsDirectory()
        let relativePath = UUID().uuidString + ".vc"
        let destURL = dir.appendingPathComponent(relativePath)

        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { coordinatedURL in
            do {
                try FileManager.default.copyItem(at: coordinatedURL, to: destURL)
                // Container contents are as sensitive as the vault itself
                // while sitting in our sandbox awaiting write-back —
                // complete protection regardless of what FileManager
                // inferred from the source (P5 file-protection audit).
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destURL.path)
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }

        let fd = Darwin.open(destURL.path, O_RDWR)
        guard fd >= 0 else { throw FdOpenError.openFailed(errno: errno) }
        return (fd, relativePath)
    }

    /// App-Support-backed holding area for copy-in fallback vaults.
    /// Excluded from iCloud/iTunes backup — these are transient working
    /// copies of a container that lives elsewhere, not the source of truth.
    static func copiedVaultsDirectory() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VaultPony", isDirectory: true)
            .appendingPathComponent("CopiedVaults", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mutableDir = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableDir.setResourceValues(values)
        return dir
    }

    /// Writes the local copy back over the original bookmark's target as a
    /// whole-file replace, coordinated so other readers see a consistent
    /// file. Called from SessionRegistry once the user confirms "Write
    /// Back" on lock.
    static func writeBack(localCopyRelativePath: String, toBookmark bookmark: Data) throws {
        var isStale = false
        let destURL = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard destURL.startAccessingSecurityScopedResource() else { throw FdOpenError.accessDenied }
        defer { destURL.stopAccessingSecurityScopedResource() }

        let srcURL = try copiedVaultsDirectory().appendingPathComponent(localCopyRelativePath)

        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destURL, options: .forReplacing, error: &coordError) { coordinatedURL in
            do {
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    try FileManager.default.removeItem(at: coordinatedURL)
                }
                try FileManager.default.copyItem(at: srcURL, to: coordinatedURL)
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    /// Deletes a copy-in working file once it's been written back (or the
    /// user chose to discard it).
    static func discardLocalCopy(_ relativePath: String) {
        if let dir = try? copiedVaultsDirectory() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(relativePath))
        }
    }
}
