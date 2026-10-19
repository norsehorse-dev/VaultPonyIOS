import Foundation
import Observation

/// Tracks the one currently-unlocked session (P1: single-session UX —
/// Unlock, browse, lock). VaultPonyApp forwards scene-background
/// transitions here: flush on background, then auto-lock (PLAN.md
/// section 6, 8).
///
/// Auto-lock (2.0.0): the delay counts from when the app goes to the
/// background (leaving the app or turning off the screen), not from the
/// last tap. 0 locks at once. Background time isn't reliable on iOS (the
/// app is usually suspended), so the deadline is also checked when the app
/// comes back, before anything is shown. The background time is recorded
/// even with nothing unlocked, so an unlock that finishes after the user
/// left still gets its deadline (`adopt`). A bulk copy holds the lock off
/// until its current file is done (`holdAutoLock`), so the vault never
/// locks with a half-written file, except when the copy runs out of
/// background time, which locks at once.
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

    /// Total and free space of the open volume. nil until fetched, and for
    /// filesystems that can't report it (the figure is hidden then).
    private(set) var space: VolumeSpace?

    /// Bumped whenever an open session is locked, so the UI can leave the
    /// vault's screens.
    private(set) var lockGeneration = 0

    /// Bumped when a bulk copy has changed the vault, so open folders reload.
    private(set) var contentGeneration = 0

    /// The bulk import or export in progress. RootView shows its progress
    /// over the whole app and the summary when it ends.
    private(set) var activeTransfer: BulkTransfer?
    var transferSummary: TransferSummary?

    /// Seconds the vault stays unlocked once the app is in the background.
    /// 0 ("Immediately") is the default; RootView sets the saved value.
    var autoLockSeconds: TimeInterval = 0

    /// An auto-lock came due while a transfer held it off; it happens as
    /// soon as the transfer lets go.
    private(set) var lockPending = false

    private var lockTask: Task<Void, Never>?
    private var backgroundedAt: ContinuousClock.Instant?
    private var holdCount = 0
    private var copyModeInfo: CopyModeInfo?

    var pendingWriteBack: PendingWriteBack?
    var lastWriteBackError: String?

    func adopt(_ session: VaultSession, vaultId: UUID, facts: VolumeFacts, copyModeInfo: CopyModeInfo? = nil) {
        self.session = session
        self.vaultId = vaultId
        self.facts = facts
        self.space = nil
        self.copyModeInfo = copyModeInfo
        self.isCopyMode = copyModeInfo != nil
        holdCount = 0
        lockPending = false
        // An unlock that finished while the app was in the background:
        // the delay started when the app left, so lock now if it has run
        // out, otherwise when the rest of it has.
        if let since = backgroundedAt {
            let delay = Duration.seconds(effectiveAutoLockSeconds)
            let elapsed = ContinuousClock.Instant.now - since
            if elapsed >= delay {
                lock()
            } else {
                scheduleAutoLock(after: delay - elapsed)
            }
        }
    }

    /// Best-effort flush; harmless no-op when nothing has been written.
    func flush() {
        try? session?.flush()
    }

    func lock() {
        lockTask?.cancel()
        lockTask = nil
        lockPending = false
        holdCount = 0
        let hadSession = session != nil
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
        space = nil
        self.copyModeInfo = nil
        isCopyMode = false
        if hadSession {
            lockGeneration += 1
        }
    }

    // MARK: - Auto-lock

    /// The app went to the background (or the screen turned off).
    func sceneDidEnterBackground() {
        flush()
        // Recorded even with nothing unlocked: an unlock still running
        // when the user left gets its deadline from here (see adopt).
        backgroundedAt = .now
        lockTask?.cancel()
        lockTask = nil
        guard session != nil else { return }
        let delay = Duration.seconds(effectiveAutoLockSeconds)
        guard delay > .zero else {
            requestAutoLock()
            return
        }
        scheduleAutoLock(after: delay)
    }

    private func scheduleAutoLock(after delay: Duration) {
        lockTask?.cancel()
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.requestAutoLock() }
        }
    }

    /// The app is in front again. Locks first if the delay ran out while
    /// the app was suspended.
    func sceneDidBecomeActive() {
        lockTask?.cancel()
        lockTask = nil
        if let since = backgroundedAt, session != nil,
           ContinuousClock.Instant.now - since >= .seconds(effectiveAutoLockSeconds) {
            requestAutoLock()
        }
        backgroundedAt = nil
    }

    /// A bulk copy is writing: an auto-lock that comes due waits for
    /// `releaseAutoLock`.
    func holdAutoLock() {
        holdCount += 1
    }

    func releaseAutoLock() {
        holdCount = max(holdCount - 1, 0)
        if holdCount == 0, lockPending {
            lock()
        }
    }

    private func requestAutoLock() {
        guard session != nil else { return }
        if holdCount > 0 {
            lockPending = true
        } else {
            lock()
        }
    }

    /// AppPrefs only hands out values from its list; this only guards the
    /// timer against anything else.
    private var effectiveAutoLockSeconds: TimeInterval {
        autoLockSeconds.isFinite ? max(autoLockSeconds, 0) : 3600
    }

    // MARK: - Volume details

    /// Re-reads free space. The first call per session counts free
    /// clusters; later ones are cheap.
    func refreshSpace() async {
        guard let session else { return }
        let fresh = try? await Vault.space(session)
        await MainActor.run {
            guard self.session === session else { return }
            self.space = fresh
        }
    }

    /// Re-reads the volume facts (writable turns false after a write was
    /// blocked to protect a hidden volume).
    func refreshFacts() async {
        guard let session else { return }
        guard let fresh = try? await Vault.facts(session) else { return }
        await MainActor.run {
            guard self.session === session else { return }
            self.facts = fresh
        }
    }

    // MARK: - Bulk transfers

    func startTransfer(_ transfer: BulkTransfer) {
        activeTransfer = transfer
        transferSummary = nil
    }

    func transferFinished(_ summary: TransferSummary) {
        activeTransfer = nil
        transferSummary = summary
        contentGeneration += 1
        Task {
            await refreshSpace()
            await refreshFacts()
        }
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
