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

    var errorDescription: String? {
        switch self {
        case .bookmarkResolutionFailed:
            return "Couldn't locate that file. It may have been moved or deleted."
        case .accessDenied:
            return "VaultPony doesn't have permission to open that file."
        case .iCloudDownloadFailed:
            return "Couldn't download the file from iCloud. Check your connection and try again."
        case .openFailed(let code):
            return "Couldn't open the file (error \(code))."
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
}
