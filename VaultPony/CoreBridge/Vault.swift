import Foundation
import UIKit
import os

/// Argon2id memory check before an unlock, in MiB.
struct MemoryCheck {
    let neededMib: Int
    let availableMib: Int

    /// Leaves headroom for the app itself and the rest of the unlock.
    var enough: Bool { availableMib >= neededMib + 64 }
}

enum Vault {
    /// `kdf` narrows which key derivations the search tries (Argon2id
    /// support, VeraCrypt 1.26.29+): `.auto` matches VeraCrypt. `cancel`
    /// stops the search before its next derivation when fired from any
    /// thread; the call then throws `VaultError.Cancelled`.
    static func unlock(fd: Int32, passphrase: String, pim: UInt32, keyfiles: [Data], kdf: KdfFilter = .auto, cancel: UnlockCancel? = nil, progress: UnlockProgressListener?) async throws -> VaultSession {
        try await Task.detached(priority: .userInitiated) {
            try VaultSession.unlockFd(fd: fd, passphrase: passphrase, pim: pim, keyfiles: keyfiles, kdf: kdf, cancel: cancel, listener: progress)
        }.value
    }

    static func unlockOuterProtected(fd: Int32, outerPassphrase: String, hiddenPassphrase: String, pim: UInt32, kdf: KdfFilter = .auto, cancel: UnlockCancel? = nil, progress: UnlockProgressListener?) async throws -> VaultSession {
        try await Task.detached(priority: .userInitiated) {
            try VaultSession.unlockOuterProtectedFd(fd: fd, outerPassphrase: outerPassphrase, hiddenPassphrase: hiddenPassphrase, pim: pim, kdf: kdf, cancel: cancel, listener: progress)
        }.value
    }

    /// What one Argon2id derivation at `pim` needs (0 = the default,
    /// 416 MiB) against what this process can still allocate before the
    /// system terminates it, both in MiB. `os_proc_available_memory()` is
    /// the per-app jetsam headroom, which is the figure that matters here.
    static func argon2MemoryCheck(pim: UInt32) -> MemoryCheck {
        MemoryCheck(
            neededMib: Int(argon2MemoryMib(pim: pim)),
            availableMib: Int(os_proc_available_memory() / (1024 * 1024))
        )
    }

    // Every call on an open session goes through FilesGate. For a vault
    // that is also shown in Files (2.0.0 rc3) that serializes it against
    // the File Provider extension and remounts after the extension wrote;
    // for any other vault it is a plain call.

    /// A read-only core call, off the main thread.
    private static func read<T>(_ session: VaultSession, _ body: @escaping () throws -> T) async throws -> T {
        try await whileShared(session) {
            try await Task.detached {
                try FilesGate.shared.perform(session, write: false, body)
            }.value
        }
    }

    /// For a vault shown in Files, the gate's file lock lives in the shared
    /// app group; iOS kills an app suspended while holding one (0xdead10cc).
    /// A background task keeps the app running until the call is done.
    /// Also used around `listBlocking` callers (the import planner).
    static func whileShared<T>(_ session: VaultSession, _ work: () async throws -> T) async rethrows -> T {
        guard FilesGate.shared.isShared(session) else { return try await work() }
        let task = await MainActor.run { () -> UIBackgroundTaskIdentifier in
            var id = UIBackgroundTaskIdentifier.invalid
            // Out of time: end the assertion rather than be killed for it.
            // The call itself finishes in moments.
            id = UIApplication.shared.beginBackgroundTask(withName: "Vault call") {
                UIApplication.shared.endBackgroundTask(id)
            }
            return id
        }
        defer {
            if task != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(task) }
            }
        }
        return try await work()
    }

    /// A core call that changes the volume. `paths` are noted so Files can
    /// be told which folders changed (on the next flush).
    private static func write<T>(_ session: VaultSession, paths: [String], _ body: @escaping () throws -> T) async throws -> T {
        try await whileShared(session) {
            try await Task.detached {
                defer {
                    if FilesGate.shared.isShared(session) {
                        paths.forEach { FilesChangeLog.shared.note($0) }
                    }
                }
                return try FilesGate.shared.perform(session, write: true, body)
            }.value
        }
    }

    static func facts(_ session: VaultSession) async throws -> VolumeFacts {
        try await read(session) { try session.facts() }
    }
    /// Total and free space (2.0.0). Throws for filesystems that can't
    /// report it, such as NTFS. The first call per session counts free
    /// clusters; later calls are cheap.
    static func space(_ session: VaultSession) async throws -> VolumeSpace {
        try await read(session) { try session.space() }
    }
    static func list(_ session: VaultSession, path: String) async throws -> [DirEntry] {
        try await read(session) { try session.list(path: path) }
    }
    static func stat(_ session: VaultSession, path: String) async throws -> DirEntry {
        try await read(session) { try session.stat(path: path) }
    }
    static func readAt(_ session: VaultSession, path: String, offset: UInt64, len: UInt32) async throws -> Data {
        try await read(session) { try session.readAt(path: path, offset: offset, len: len) }
    }

    /// `list` for synchronous code that is already off the main thread (the
    /// import planner's folder lookups). Gated like every other call; the
    /// caller must run inside `whileShared` so the app isn't suspended
    /// holding the gate (ImportWalker.plan does).
    static func listBlocking(_ session: VaultSession, path: String) throws -> [DirEntry] {
        try FilesGate.shared.perform(session, write: false) { try session.list(path: path) }
    }

    // MARK: - P2: write path
    static func create(_ session: VaultSession, path: String) async throws {
        try await write(session, paths: [path]) { try session.create(path: path) }
    }
    static func mkdir(_ session: VaultSession, path: String) async throws {
        try await write(session, paths: [path]) { try session.mkdir(path: path) }
    }
    static func rename(_ session: VaultSession, from: String, to: String) async throws {
        try await write(session, paths: [from, to]) { try session.rename(from: from, to: to) }
    }
    static func remove(_ session: VaultSession, path: String) async throws {
        try await write(session, paths: [path]) { try session.remove(path: path) }
    }
    static func truncate(_ session: VaultSession, path: String, len: UInt64) async throws {
        try await write(session, paths: [path]) { try session.truncate(path: path, len: len) }
    }
    @discardableResult
    static func writeAt(_ session: VaultSession, path: String, offset: UInt64, data: Data) async throws -> UInt32 {
        try await write(session, paths: [path]) { try session.writeAt(path: path, offset: offset, data: data) }
    }
    /// Puts `src` in place of `dst` (replacing it), then flushes.
    static func replace(_ session: VaultSession, src: String, dst: String) async throws {
        try await write(session, paths: [src, dst]) { try session.replace(src: src, dst: dst) }
    }

    /// Flushes, and tells Files which folders the app changed since the
    /// last flush.
    static func flush(_ session: VaultSession) async throws {
        try await write(session, paths: []) { try session.flush() }
        let folders = FilesChangeLog.shared.take()
        if !folders.isEmpty {
            await MainActor.run { FilesBridge.shared.signal(folders: folders) }
        }
    }

    // MARK: - P3: container creation
    //
    // Named distinctly from the generated global funcs (createContainer,
    // createHiddenContainer, encryptionSchemes, hashes, filesystems) so
    // the unqualified calls below resolve to Rust, not back into this
    // enum — the same trap that bit `core_version()` in P0 when a
    // same-named wrapper called itself instead of the generated function.

    /// Formats a brand-new container over `fd` (a freshly-created, empty,
    /// writable file the caller owns — see FdOpener.openForImport). The
    /// core sizes the file itself via `set_len`.
    static func createNewContainer(fd: Int32, size: UInt64, passphrase: String, pim: UInt32, keyfiles: [Data], scheme: String, prf: String, filesystem: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try createContainer(fd: fd, size: size, passphrase: passphrase, pim: pim, keyfiles: keyfiles, scheme: scheme, prf: prf, filesystem: filesystem)
        }.value
    }

    /// Formats a container that hides a second volume inside the first
    /// (doc §9). `fd` is a single freshly-created, writable file; the
    /// core dup's it internally for the outer/hidden passes.
    static func createNewHiddenContainer(fd: Int32, size: UInt64, outerPassphrase: String, hiddenPassphrase: String, pim: UInt32, hiddenSize: UInt64, scheme: String, prf: String, filesystem: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try createHiddenContainer(fd: fd, size: size, outerPassphrase: outerPassphrase, hiddenPassphrase: hiddenPassphrase, pim: pim, hiddenSize: hiddenSize, scheme: scheme, prf: prf, filesystem: filesystem)
        }.value
    }

    /// Registry lookups are cheap, synchronous, and side-effect-free — no
    /// need to hop off the main actor for these.
    static func encryptionSchemeOptions() -> [String] { encryptionSchemes() }
    static func hashOptions() -> [String] { hashes() }
    static func filesystemOptions() -> [String] { filesystems() }

    // MARK: - 2.0.0 rc4: hash menu and scheme names (D16, D21)
    //
    // Same naming rule: none of these shares a name with the generated
    // globals (hashChoices, kdfFilterForPrf, kdfFilterMayUseArgon2,
    // schemeDisplayName).

    /// The unlock screen's "Hash" menu: Auto, then each hash in VeraCrypt's
    /// order. Only "Auto" is translated; the rest are hash names.
    static func hashMenuChoices() -> [HashChoice] { hashChoices() }

    /// The single-hash filter for a hash name (a menu label, or
    /// `VolumeFacts.prf`), or nil.
    static func kdfFilter(forHash name: String) -> KdfFilter? { kdfFilterForPrf(prf: name) }

    /// Whether an unlock under `filter` may run Argon2id, so the memory
    /// check runs first.
    static func mayUseArgon2(_ filter: KdfFilter) -> Bool { kdfFilterMayUseArgon2(filter: filter) }

    /// What the user sees for a scheme ("AES-Twofish-Serpent" for the core's
    /// "AES(Twofish(Serpent))"). The core keeps taking the registry name.
    static func schemeLabel(_ name: String) -> String { schemeDisplayName(name: name) }

    // MARK: - P4: custody — change password, header backup/restore
    //
    // Same naming rule as P3: every wrapper name here is distinct from
    // its generated global counterpart (changePassword, exportHeaderBackup,
    // restoreHeaderFromFile, restoreHeaderFromEmbedded).
    //
    // These operate on a raw fd, not an active VaultSession — the caller
    // opens the bookmark itself (FdOpener.openForUnlock), same as an
    // unlock, but never actually unlocks a session for these.

    /// Re-keys a container's header under a new password/PIM/keyfiles;
    /// the data area is untouched. `fd` must be opened read-write. The
    /// old credentials are verified before anything is written — a wrong
    /// old password changes nothing.
    ///
    /// `newPrf` moves the header to another KDF/hash (a core registry
    /// name such as "Argon2id"); nil keeps the current one. `newPim` is
    /// read under the KDF the header ends up with, so 0 means its default.
    static func changeContainerPassword(fd: Int32, oldPassphrase: String, oldPim: UInt32, oldKeyfiles: [Data], newPassphrase: String, newPim: UInt32, newKeyfiles: [Data], newPrf: String? = nil) async throws {
        try await Task.detached(priority: .userInitiated) {
            try changePassword(fd: fd, oldPassphrase: oldPassphrase, oldPim: oldPim, oldKeyfiles: oldKeyfiles, newPassphrase: newPassphrase, newPim: newPim, newKeyfiles: newKeyfiles, newPrf: newPrf, kdf: .auto, cancel: nil)
        }.value
    }

    /// Reads the container's 128 KiB header backup over a read-only `fd`,
    /// for the caller to save externally (doc §6). The bytes are
    /// ciphertext under the container's current password — no auth
    /// needed to export, but the caller must warn the user to guard the
    /// exported file, since it keeps accepting that password forever.
    static func backupHeader(fd: Int32) async throws -> Data {
        try await Task.detached { try exportHeaderBackup(fd: fd) }.value
    }

    /// Restores the primary header from a previously-exported `backup`'s
    /// bytes over a writable `fd`. Verifies against
    /// passphrase/pim/keyfiles before writing; a wrong password leaves
    /// the container untouched.
    static func restoreHeaderFromBackupFile(fd: Int32, backup: Data, passphrase: String, pim: UInt32, keyfiles: [Data]) async throws {
        try await Task.detached(priority: .userInitiated) {
            try restoreHeaderFromFile(fd: fd, backup: backup, passphrase: passphrase, pim: pim, keyfiles: keyfiles, kdf: .auto, cancel: nil)
        }.value
    }

    /// Restores the primary header from the container's own embedded
    /// tail backup over a writable `fd` — no external file needed. Same
    /// verify-before-write guarantee as the file-based restore.
    static func restoreHeaderFromEmbeddedBackup(fd: Int32, passphrase: String, pim: UInt32, keyfiles: [Data]) async throws {
        try await Task.detached(priority: .userInitiated) {
            try restoreHeaderFromEmbedded(fd: fd, passphrase: passphrase, pim: pim, keyfiles: keyfiles, kdf: .auto, cancel: nil)
        }.value
    }

    // MARK: - P5: about screen
    static func coreVersionText() -> String { coreVersion() }
}
