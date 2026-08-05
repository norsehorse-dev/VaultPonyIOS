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

    // MARK: - P2: write path

    static func create(_ session: VaultSession, path: String) async throws {
        try await Task.detached { try session.create(path: path) }.value
    }

    static func mkdir(_ session: VaultSession, path: String) async throws {
        try await Task.detached { try session.mkdir(path: path) }.value
    }

    static func rename(_ session: VaultSession, from: String, to: String) async throws {
        try await Task.detached { try session.rename(from: from, to: to) }.value
    }

    static func remove(_ session: VaultSession, path: String) async throws {
        try await Task.detached { try session.remove(path: path) }.value
    }

    static func truncate(_ session: VaultSession, path: String, len: UInt64) async throws {
        try await Task.detached { try session.truncate(path: path, len: len) }.value
    }

    @discardableResult
    static func writeAt(_ session: VaultSession, path: String, offset: UInt64, data: Data) async throws -> UInt32 {
        try await Task.detached { try session.writeAt(path: path, offset: offset, data: data) }.value
    }

    static func flush(_ session: VaultSession) async throws {
        try await Task.detached { try session.flush() }.value
    }
}
