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
///
/// The Home Screen quick action "Lock vaults" (2.0.0) is kept in step with
/// the session here: added when a session is adopted, removed on lock.
///
/// Files access (2.0.0 rc3, D18 to D20): with "Show in Files" the session is
/// also handed to the File Provider extension (FilesBridge). The auto-lock
/// then follows FilesPolicy: the vault stays open until the delay (2 minutes
/// for "Immediately") after the later of leaving the app and the last Files
/// activity, never more than 1 hour after leaving. The extension enforces
/// the same rule itself while the app is suspended; both read the clock from
/// FilesGate. Locking from anywhere tears Files access down.
@Observable
final class SessionRegistry {
    /// The app's one registry. VaultPonyApp puts it in the environment;
    /// the scene delegate reaches it here for the Home Screen quick action,
    /// which can arrive before any view exists.
    static let shared = SessionRegistry()

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

    /// The open vault is also shown in Files (2.0.0 rc3).
    private(set) var filesShared = false
    private var filesWritable = false
    private var heartbeatTask: Task<Void, Never>?
    /// "Show in Files" was asked for but couldn't be turned on.
    var filesError: String?

    /// The volume opened read-only (TrueCrypt, ext4, NTFS), so a local
    /// copy of it was never written and goes at lock without asking.
    private var openedReadOnly = false

    /// "Convert to VeraCrypt" (2.0.0 rc5, plan 6.2). RootView shows it over
    /// the whole app, so it outlives a lock that leaves the vault's screens.
    private(set) var activeConvert: ConvertJob?

    /// The open session was unlocked somewhere other than the unlock screen
    /// ("Open new vault" after a conversion): HomeView shows its browser.
    private(set) var showSessionOnHome = false

    /// The camera (2.0.0 rc5) drops an unfinished video here, before the
    /// keys go. Called on the main actor at the start of every lock of an
    /// open session.
    @ObservationIgnored var cameraWillLock: (@MainActor () -> Void)?

    /// `filesFd` (a dup of the container fd, owned from here on) asks for
    /// Files access too.
    /// `showInBrowser` asks HomeView to show the vault's browser.
    func adopt(_ session: VaultSession, vaultId: UUID, facts: VolumeFacts, copyModeInfo: CopyModeInfo? = nil, filesFd: Int32? = nil, showInBrowser: Bool = false) {
        self.session = session
        self.vaultId = vaultId
        self.facts = facts
        self.space = nil
        self.copyModeInfo = copyModeInfo
        self.isCopyMode = copyModeInfo != nil
        self.openedReadOnly = !facts.writable
        self.showSessionOnHome = showInBrowser
        holdCount = 0
        lockPending = false
        if let filesFd {
            if copyModeInfo != nil {
                // Its edits only reach the real file at lock, through a
                // prompt Files can't show (D20).
                close(filesFd)
                filesError = String(localized: "Show in Files isn't available for this vault, because its location doesn't allow editing in place.", locale: LanguageOverride.locale)
            } else {
                startFiles(session, fd: filesFd, writable: facts.writable)
            }
        }
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
        refreshQuickAction()
    }

    /// Best-effort flush; harmless no-op when nothing has been written.
    func flush() {
        guard let session else { return }
        _ = try? FilesGate.shared.perform(session, write: false) { try session.flush() }
    }

    /// `keepingTransient` is a vault about to be adopted ("Open new vault"
    /// after a conversion): its in-memory list entry stays.
    func lock(keepingTransient keep: UUID? = nil) {
        lockTask?.cancel()
        lockTask = nil
        lockPending = false
        holdCount = 0
        let hadSession = session != nil
        if hadSession {
            letGoBeforeLock()
        }
        showSessionOnHome = false
        clearDecryptedState(sessionWasOpen: hadSession)
        if filesShared {
            // Teardown asks the extension to store any save still waiting
            // and lock, then posts the Darwin notification as a fallback.
            if let session {
                _ = try? FilesGate.shared.perform(session, write: false) { try session.flush() }
                FilesGate.shared.unregister(session)
            }
            filesShared = false
            heartbeatTask?.cancel()
            heartbeatTask = nil
            Task { @MainActor in await FilesBridge.shared.teardown() }
        }
        let lockedVaultId = vaultId
        try? session?.flush()
        session?.lock()
        session = nil
        if let copyModeInfo, let vaultId {
            if openedReadOnly {
                // Nothing could have changed it: no "Save Changes?".
                FdOpener.discardLocalCopy(copyModeInfo.relativePath)
            } else {
                pendingWriteBack = PendingWriteBack(
                    vaultId: vaultId,
                    localCopyRelativePath: copyModeInfo.relativePath,
                    bookmark: copyModeInfo.bookmark,
                    displayName: copyModeInfo.displayName
                )
            }
        }
        openedReadOnly = false
        vaultId = nil
        facts = nil
        space = nil
        self.copyModeInfo = nil
        isCopyMode = false
        if hadSession {
            lockGeneration += 1
            // A vault list that keeps nothing drops what just locked, here
            // rather than in a view, so every lock path does it.
            VaultStore.shared.vaultLocked(
                lockedVaultId,
                removeIt: AppPrefs.shared.vaultListMode == .dontKeep,
                unlockedId: keep
            )
        }
        refreshQuickAction()
    }

    /// The camera discards a video it was recording and a conversion stops
    /// and locks its new container, while the vault is still open (2.0.0
    /// rc5). Every lock path comes through here.
    private func letGoBeforeLock() {
        let camera = cameraWillLock
        let convert = activeConvert
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                camera?()
                convert?.sourceWillLock()
            }
        } else {
            Task { @MainActor in
                camera?()
                convert?.sourceWillLock()
            }
        }
    }

    /// What 2.0.0 rc4 keeps in memory or on disk from an open vault goes
    /// before its keys: grid thumbnails, players streaming from it, and a
    /// share waiting to be imported (its staged plaintext). A lock with no
    /// vault open leaves a share alone: the user may be about to unlock one
    /// for it.
    private func clearDecryptedState(sessionWasOpen: Bool) {
        ThumbnailCache.shared.removeAll()
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                MediaPlayback.stopAll()
                if sessionWasOpen {
                    ShareInbox.shared.removeAllClaimed()
                }
            }
        } else {
            Task { @MainActor in
                MediaPlayback.stopAll()
                if sessionWasOpen {
                    ShareInbox.shared.removeAllClaimed()
                }
            }
        }
    }

    /// The Home Screen quick action: locks now, whatever the auto-lock
    /// delay or a copy's hold. A copy in progress stops at its next chunk
    /// and reports what was copied, as when its background time runs out.
    /// HomeView leaves the vault's screens on the lockGeneration bump.
    @MainActor
    func lockAll() {
        activeTransfer?.stopForLock()
        lock()
    }

    /// Shows the "Lock vaults" quick action while a vault is unlocked and
    /// removes it otherwise. Also called after an in-app language change
    /// so the title follows it.
    func refreshQuickAction() {
        if Thread.isMainThread {
            let unlocked = session != nil
            MainActor.assumeIsolated {
                QuickActions.sync(unlocked: unlocked)
            }
        } else {
            Task { @MainActor [weak self] in
                QuickActions.sync(unlocked: self?.session != nil)
            }
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
        if filesShared {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            FilesGate.shared.setLeftApp(FilesClock.now())
            scheduleFilesCheck()
            return
        }
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
        if filesShared, let session {
            let times = FilesGate.shared.times()
            if filesPolicy.expired(now: FilesClock.now(), leftApp: times.leftApp, lastActivity: times.lastActivity) {
                requestAutoLock()
            } else {
                FilesGate.shared.setLeftApp(nil)
                startHeartbeat()
                // Files may have changed the vault while the app was away.
                contentGeneration += 1
                let policy = filesPolicy
                Task { @MainActor in
                    // iOS may have stopped the extension meanwhile; hand
                    // the vault over again (no password needed).
                    try? await FilesBridge.shared.refresh(session: session, policy: policy)
                }
            }
            backgroundedAt = nil
            return
        }
        if let since = backgroundedAt, session != nil,
           ContinuousClock.Instant.now - since >= .seconds(effectiveAutoLockSeconds) {
            requestAutoLock()
        }
        backgroundedAt = nil
        if session == nil || !filesShared {
            // Clears any Files domain a crash or kill left behind.
            Task { @MainActor in await FilesBridge.shared.sweep() }
        }
    }

    // MARK: - Files access (2.0.0 rc3)

    private var filesPolicy: FilesPolicy {
        FilesPolicy(delaySeconds: effectiveAutoLockSeconds, writable: filesWritable)
    }

    private func startFiles(_ session: VaultSession, fd: Int32, writable: Bool) {
        filesShared = true
        filesWritable = writable
        FilesGate.shared.resetForNewShare()
        FilesGate.shared.setLeftApp(nil)
        startHeartbeat()
        let policy = filesPolicy
        Task { @MainActor in
            do {
                try await FilesBridge.shared.share(session: session, fd: fd, policy: policy)
                if self.session !== session {
                    // Locked while Files was being set up.
                    await FilesBridge.shared.teardown()
                }
            } catch {
                FilesGate.shared.unregister(session)
                guard self.session === session else { return }
                self.filesShared = false
                self.heartbeatTask?.cancel()
                self.heartbeatTask = nil
                self.filesError = String(localized: "Couldn't show this vault in Files.", locale: LanguageOverride.locale)
            }
        }
    }

    /// While the app is in front, the extension must not start its clock;
    /// a heartbeat tells it the app is still there (and stops if it crashes).
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                FilesGate.shared.heartbeat()
                try? await Task.sleep(for: .seconds(FilesGate.heartbeatSeconds))
            }
        }
    }

    /// In the background with Files access: lock when FilesPolicy says so.
    /// Files activity can move the deadline, so it is re-read each time.
    private func scheduleFilesCheck() {
        let times = FilesGate.shared.times()
        guard let left = times.leftApp else { return }
        let deadline = filesPolicy.deadline(leftApp: left, lastActivity: times.lastActivity)
        let now = FilesClock.now()
        let wait = deadline > now ? Double(deadline - now) / 1_000_000_000 : 0
        lockTask?.cancel()
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait + 0.5))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.filesCheck() }
        }
    }

    private func filesCheck() {
        guard filesShared, session != nil else { return }
        let times = FilesGate.shared.times()
        if filesPolicy.expired(now: FilesClock.now(), leftApp: times.leftApp, lastActivity: times.lastActivity) {
            requestAutoLock()
        } else {
            scheduleFilesCheck()
        }
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
            if self.filesShared, self.filesWritable != fresh.writable {
                self.filesWritable = fresh.writable
                let policy = self.filesPolicy
                Task { @MainActor in
                    try? await FilesBridge.shared.refresh(session: session, policy: policy)
                }
            }
        }
    }

    // MARK: - Convert to VeraCrypt (2.0.0 rc5)

    func startConvert(_ job: ConvertJob) {
        activeConvert = job
    }

    func endConvert() {
        activeConvert = nil
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
