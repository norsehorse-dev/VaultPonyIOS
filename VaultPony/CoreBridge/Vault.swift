import Foundation

enum Vault {
    static func unlock(fd: Int32, passphrase: String, pim: UInt32, keyfiles: [Data], progress: UnlockProgressListener?) async throws -> VaultSession {
        try await Task.detached(priority: .userInitiated) {
            try VaultSession.unlockFd(fd: fd, passphrase: passphrase, pim: pim, keyfiles: keyfiles, listener: progress)
        }.value
    }

    static func unlockOuterProtected(fd: Int32, outerPassphrase: String, hiddenPassphrase: String, pim: UInt32, progress: UnlockProgressListener?) async throws -> VaultSession {
        try await Task.detached(priority: .userInitiated) {
            try VaultSession.unlockOuterProtectedFd(fd: fd, outerPassphrase: outerPassphrase, hiddenPassphrase: hiddenPassphrase, pim: pim, listener: progress)
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
}
