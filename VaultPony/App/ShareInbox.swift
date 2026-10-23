import Foundation
import Observation

/// A share the app has taken out of the app group, waiting to be imported.
/// Its files live in the app's own temporary directory.
struct IncomingShare: Identifiable, Equatable {
    /// The share's token.
    let id: UUID
    let folder: URL
    let files: [URL]
}

/// The app's side of "Save to VaultPony" (2.0.0 rc4, plan 5.1). See
/// `ShareStaging` for the hand-off itself.
///
/// A share is claimed as soon as the app hears of it, from the
/// `vaultpony://share` URL or, if the extension couldn't open the app, on
/// the next launch or return to the foreground: the staged folder is moved
/// out of the app group into the app's temporary directory before anything
/// else happens. RootView then asks where to save it. The claimed copy is
/// deleted when the import ends, when the user cancels, and at every lock.
@MainActor
@Observable
final class ShareInbox {
    static let shared = ShareInbox()

    /// The share waiting for a destination.
    private(set) var pending: IncomingShare?
    /// The user picked a vault to unlock from the share sheet. The sheet
    /// shows again once a vault is unlocked, or when they go back to the
    /// vault list without unlocking.
    var awaitingUnlock = false
    /// HomeView opens this vault's unlock screen, then clears it.
    var vaultToUnlock: SavedVault?

    private static var claimedRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("IncomingShare", isDirectory: true)
    }

    /// `vaultpony://share?token=<UUID>`. Anything else is ignored.
    func handle(_ url: URL) {
        guard let token = ShareStaging.token(from: url) else { return }
        claim(token)
    }

    /// At launch and on every return to the foreground: claims the newest
    /// complete share younger than 10 minutes if none is waiting, and
    /// deletes staged shares older than that.
    func pickUp() {
        let now = Date()
        var newest: ShareStaging.Waiting?
        for waiting in ShareStaging.waiting() {
            guard let created = waiting.created,
                  now.timeIntervalSince(created) <= ShareStaging.maxAge,
                  created <= now.addingTimeInterval(60)
            else {
                ShareStaging.remove(token: waiting.token)
                continue
            }
            guard waiting.isComplete else { continue }
            if let best = newest, let bestCreated = best.created, bestCreated >= created { continue }
            newest = waiting
        }
        if pending == nil, let newest {
            claim(newest.token)
        }
    }

    /// Moves a staged share into the app's temporary directory and makes it
    /// the pending one.
    private func claim(_ token: UUID) {
        guard pending?.id != token, let source = ShareStaging.folder(token: token) else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        let dest = Self.claimedRoot.appendingPathComponent(token.uuidString, isDirectory: true)
        do {
            try manager.createDirectory(
                at: Self.claimedRoot,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try? manager.removeItem(at: dest)
            try manager.moveItem(at: source, to: dest)
        } catch {
            ShareStaging.remove(token: token)
            return
        }
        ShareStaging.protect(dest)
        guard let names = ShareStaging.readManifest(in: dest) else {
            try? manager.removeItem(at: dest)
            return
        }
        let filesFolder = dest.appendingPathComponent(ShareStaging.filesFolder, isDirectory: true)
        var files: [URL] = []
        for name in names where ShareStaging.safeName(name) == name {
            let url = filesFolder.appendingPathComponent(name, isDirectory: false)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            ShareStaging.protect(url)
            files.append(url)
        }
        guard !files.isEmpty else {
            try? manager.removeItem(at: dest)
            return
        }
        if let previous = pending {
            try? manager.removeItem(at: previous.folder)
        }
        pending = IncomingShare(id: token, folder: dest, files: files)
        awaitingUnlock = false
        vaultToUnlock = nil
    }

    /// The user cancelled.
    func discard() {
        if let pending {
            try? FileManager.default.removeItem(at: pending.folder)
        }
        pending = nil
        awaitingUnlock = false
        vaultToUnlock = nil
    }

    /// The import of `share` is starting: it is no longer pending, and its
    /// files are deleted by `importEnded` once the copy finishes.
    func beginImport(_ share: IncomingShare) {
        if pending?.id == share.id {
            pending = nil
        }
        awaitingUnlock = false
        vaultToUnlock = nil
    }

    func importEnded(_ share: IncomingShare) {
        try? FileManager.default.removeItem(at: share.folder)
        pickUp()
    }

    /// At lock and at launch: every claimed share goes, pending or being
    /// imported.
    func removeAllClaimed() {
        pending = nil
        awaitingUnlock = false
        vaultToUnlock = nil
        try? FileManager.default.removeItem(at: Self.claimedRoot)
    }
}
