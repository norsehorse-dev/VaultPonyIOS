import Foundation
import Observation

/// Tracks the one currently-unlocked session (P1: single-session UX —
/// Unlock, browse, lock). Auto-locks after autoLockSeconds of inactivity;
/// VaultPonyApp also calls lock()/flush() on scene-background transitions
/// (PLAN.md section 6, 8).
///
/// P2 adds copy-mode tracking: when a container had to be opened via
/// FdOpener.openViaCopyIn (its real location wouldn't hand back a
/// writable fd), lock() stages a PendingWriteBack instead of silently
/// discarding the edited copy — VaultPonyApp surfaces it as an alert.
@Observable
final class SessionRegistry {
    private(set) var session: VaultSession?
    private(set) var vaultId: UUID?
    private(set) var facts: VolumeFacts?
    private(set) var isCopyMode: Bool = false

    var autoLockSeconds: TimeInterval = 300
    private var lockTask: Task<Void, Never>?
    private var copyModeInfo: CopyModeInfo?

    var pendingWriteBack: PendingWriteBack?
    var lastWriteBackError: String?

    func adopt(_ session: VaultSession, vaultId: UUID, facts: VolumeFacts, copyModeInfo: CopyModeInfo? = nil) {
        self.session = session
        self.vaultId = vaultId
        self.facts = facts
        self.copyModeInfo = copyModeInfo
        self.isCopyMode = copyModeInfo != nil
        resetAutoLockTimer()
    }

    func markActivity() {
        guard session != nil else { return }
        resetAutoLockTimer()
    }

    /// Best-effort flush; harmless no-op when nothing has been written.
    func flush() {
        try? session?.flush()
    }

    func lock() {
        lockTask?.cancel()
        lockTask = nil
        try? session?.flush()
        session?.lock()
        session = nil
        if let copyModeInfo, let vaultId {
            pendingWriteBack = PendingWriteBack(
                vaultId: vaultId,
                localCopyRelativePath: copyModeInfo.relativePath,
                bookmark: copyModeInfo.bookmark,
                displayName: copyModeInfo.displayName
            )
        }
        vaultId = nil
        facts = nil
        self.copyModeInfo = nil
        isCopyMode = false
    }

    /// Resolves a pending copy-mode write-back per the user's alert choice.
    func resolveWriteBack(_ pending: PendingWriteBack, writeBack: Bool) async {
        defer { pendingWriteBack = nil }
        if writeBack {
            do {
                try await Task.detached {
                    try FdOpener.writeBack(localCopyRelativePath: pending.localCopyRelativePath, toBookmark: pending.bookmark)
                }.value
                FdOpener.discardLocalCopy(pending.localCopyRelativePath)
            } catch {
                lastWriteBackError = error.localizedDescription
            }
        } else {
            FdOpener.discardLocalCopy(pending.localCopyRelativePath)
        }
    }

    private func resetAutoLockTimer() {
        lockTask?.cancel()
        lockTask = nil
        let seconds = autoLockSeconds
        // P5: Settings offers a "Never" auto-lock option, represented as
        // .infinity. Duration.seconds() can't represent that (it traps
        // converting an infinite Double) — simply don't schedule a lock
        // task at all in that case, matching Android's "Off" semantics.
        guard seconds.isFinite else { return }
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.lock() }
        }
    }
}

/// Records that the current session is editing a local copy, not the
/// original file in place, and what's needed to write it back later.
struct CopyModeInfo {
    let relativePath: String
    let bookmark: Data
    let displayName: String
}

/// Surfaced to VaultPonyApp as a "Save Changes?" alert once lock() finds
/// a copy-mode session ending.
struct PendingWriteBack: Identifiable {
    let id = UUID()
    let vaultId: UUID
    let localCopyRelativePath: String
    let bookmark: Data
    let displayName: String
}
