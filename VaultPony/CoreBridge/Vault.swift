import Foundation

/// Async facade over the generated VaultFFI bindings (PLAN.md section 4).
/// Screens call through here, never VaultSession/VaultError directly, so
/// the blocking-call-off-main-thread rule lives in exactly one place.
/// VaultSession's own calls are synchronous and thread-safe (serialize on
/// an internal lock per its doc comment), so Task.detached is enough — no
/// dedicated actor needed.
enum Vault {
    static func unlock(
        fd: Int32,
        passphrase: String,
        pim: UInt32,
        keyfiles: [Data],
        progress: UnlockProgressListener?
    ) async throws -> VaultSession {
        try await Task.detached(priority: .userInitiated) {
            try VaultSession.unlockFd(fd: fd, passphrase: passphrase, pim: pim, keyfiles: keyfiles, listener: progress)
        }.value
    }

    static func unlockOuterProtected(
        fd: Int32,
        outerPassphrase: String,
        hiddenPassphrase: String,
        pim: UInt32,
        progress: UnlockProgressListener?
    ) async throws -> VaultSession {
        try await Task.detached(priority: .userInitiated) {
            try VaultSession.unlockOuterProtectedFd(
                fd: fd,
                outerPassphrase: outerPassphrase,
                hiddenPassphrase: hiddenPassphrase,
                pim: pim,
                listener: progress
            )
        }.value
    }

    static func facts(_ session: VaultSession) async throws -> VolumeFacts {
        try await Task.detached { try session.facts() }.value
    }

    static func list(_ session: VaultSession, path: String) async throws -> [DirEntry] {
        try await Task.detached { try session.list(path: path) }.value
    }

    static func stat(_ session: VaultSession, path: String) async throws -> DirEntry {
        try await Task.detached { try session.stat(path: path) }.value
    }

    static func readAt(_ session: VaultSession, path: String, offset: UInt64, len: UInt32) async throws -> Data {
        try await Task.detached { try session.readAt(path: path, offset: offset, len: len) }.value
    }
}
