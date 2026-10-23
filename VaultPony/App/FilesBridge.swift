import FileProvider
import Foundation
import os
import UIKit

/// The app's side of Files access (2.0.0 rc3, plan 4.2, D18 to D20).
///
/// "Show in Files" on the unlock screen adds a File Provider domain with a
/// random id and the generic name "VaultPony", then hands the unlocked
/// session to the extension over its restricted XPC service: the core's key
/// handoff blob, a dup of the container fd, a fresh item-id key, the
/// auto-lock policy, and a per-share token. Locking tears it all down: the
/// extension is asked to lock (it stores any save still waiting first), a
/// Darwin notification follows in case that call didn't land, the domain is
/// removed, and its materialized files are deleted.
@MainActor
final class FilesBridge {
    static let shared = FilesBridge()

    /// One share at a time. Teardown clears this at once, so a new share can
    /// start while the old one is still being cleaned up.
    private struct Share {
        let domain: NSFileProviderDomain
        let idKey: Data
        let token: Data
        /// The app's own dup of the container fd, kept to hand the extension
        /// a fresh dup whenever it needs the vault again.
        let containerFd: Int32
        var lastPolicy: FilesPolicy?
    }

    private var share: Share?
    /// A share is being set up; a sweep must not remove its new domain.
    private var sharing = false
    /// The teardown in progress. A new share waits for it, so the old
    /// lock call, its Darwin notification and its token cleanup can never
    /// hit the new share.
    private var teardownTask: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.norsehorse.vaultpony", category: "files")

    var isActive: Bool { share != nil }

    /// Adds the domain and hands `session` over. Takes ownership of `fd`
    /// (closed at teardown, or here on failure).
    func share(session: VaultSession, fd: Int32, policy: FilesPolicy) async throws {
        sharing = true
        defer { sharing = false }
        await teardown()
        let id = UUID().uuidString
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(id),
            displayName: FilesShared.domainDisplayName,
            pathRelativeToDocumentStorage: id
        )
        let token: Data
        do {
            token = try FilesToken.mint()
            try await NSFileProviderManager.add(domain)
        } catch {
            close(fd)
            FilesToken.clear()
            throw error
        }
        share = Share(domain: domain, idKey: ItemIDCodec.randomKey(), token: token, containerFd: fd, lastPolicy: nil)
        FilesGate.shared.register(session)
        do {
            // Publish what the app wrote before the gate covered it, so the
            // extension mounts a consistent volume.
            try await Task.detached {
                try FilesGate.shared.perform(session, write: true) { try session.flush() }
            }.value
            try await push(session: session, policy: policy)
        } catch {
            await teardown()
            throw error
        }
        log.info("files access on")
    }

    /// Hands the session to the extension (again). The extension keeps a
    /// session it already holds and only takes the new policy.
    func push(session: VaultSession, policy: FilesPolicy) async throws {
        guard let current = share else { return }
        // Swift and XPC keep copies of this that can't be wiped; it lives
        // only for this call (THREAT_MODEL-IOS section 9).
        let blob = try await Task.detached { try session.exportHandoff() }.value
        let dupFd = dup(current.containerFd)
        guard dupFd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF) }
        let handle = FileHandle(fileDescriptor: dupFd, closeOnDealloc: true)
        defer { try? handle.close() }
        let policyData = policy.encoded()
        try await call(current, timeout: 15) { proxy, finish in
            proxy.adopt(blob, container: handle, idKey: current.idKey, policy: policyData, token: current.token) { error in
                finish(error)
            }
        }
        if share?.domain == current.domain {
            share?.lastPolicy = policy
        }
    }

    /// On return to the app: hand the vault over again if iOS stopped the
    /// extension, or if the policy changed (auto-lock delay, read-only).
    func refresh(session: VaultSession, policy: FilesPolicy) async throws {
        guard let current = share else { return }
        if policy == current.lastPolicy, await extensionHoldsVault() {
            return
        }
        try await push(session: session, policy: policy)
    }

    /// Whether the extension still holds the vault.
    func extensionHoldsVault() async -> Bool {
        guard let current = share else { return false }
        let box = ResultBox()
        try? await call(current, timeout: 5) { proxy, finish in
            proxy.status(token: current.token) { value in
                box.value = value
                finish(nil)
            }
        }
        return box.value
    }

    /// Lock in the extension, remove the domain, delete its files. The
    /// share's state is cleared first; a new share waits for this to finish.
    func teardown() async {
        if let running = teardownTask {
            await running.value
        }
        guard let old = share else { return }
        share = nil
        let task = Task { @MainActor in
            await self.cleanUp(old)
        }
        teardownTask = task
        await task.value
        if teardownTask == task {
            teardownTask = nil
        }
    }

    private func cleanUp(_ old: Share) async {
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Lock Files access") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        defer {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        // The extension stores saves that are still waiting, then locks. It
        // replies only once it has.
        try? await call(old, timeout: 20) { proxy, finish in
            proxy.lock(token: old.token) { finish(nil) }
        }
        Self.postLockNotification()
        do {
            _ = try await NSFileProviderManager.remove(old.domain, mode: .removeAll)
        } catch {
            try? await NSFileProviderManager.remove(old.domain)
        }
        let storage = FilesShared.domainStorage(old.domain)
        try? FileManager.default.removeItem(at: storage)
        if FileManager.default.fileExists(atPath: storage.path) {
            // The spike's lock sequence: a lock that left plaintext behind
            // must not go unnoticed. The next sweep retries.
            log.error("files storage not removed at lock")
            SessionRegistry.shared.filesError = String(localized: "VaultPony couldn't remove every file it showed in Files. They will be removed the next time you open VaultPony.", locale: LanguageOverride.locale)
        }
        close(old.containerFd)
        FilesToken.clear()
        log.info("files access off")
    }

    /// Tells a running extension to lock. Any app can post this; it can
    /// only ever lock early.
    nonisolated static func postLockNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(FilesShared.lockNotification as CFString),
            nil,
            nil,
            true
        )
    }

    /// With nothing shared: removes any domain and file a crash or a kill
    /// left behind. Run at launch and on every return to the foreground.
    func sweep() async {
        guard share == nil, !sharing, teardownTask == nil else { return }
        if let domains = try? await NSFileProviderManager.domains(), !domains.isEmpty {
            Self.postLockNotification()
            for leftover in domains {
                do {
                    _ = try await NSFileProviderManager.remove(leftover, mode: .removeAll)
                } catch {
                    try? await NSFileProviderManager.remove(leftover)
                }
            }
        }
        guard share == nil, !sharing, teardownTask == nil else { return }
        let storage = NSFileProviderManager.default.documentStorageURL
        if let children = try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil) {
            for child in children {
                try? FileManager.default.removeItem(at: child)
            }
        }
        FilesToken.clear()
    }

    /// Asks Files to list these vault folders again after the app changed
    /// them.
    func signal(folders: Set<String>) {
        guard let current = share, let manager = NSFileProviderManager(for: current.domain) else { return }
        let codec = ItemIDCodec(key: current.idKey)
        for folder in folders {
            manager.signalEnumerator(for: codec.identifier(for: folder)) { _ in }
        }
    }

    // MARK: XPC

    /// One XPC call on a fresh connection. Fails on timeout, or as soon as
    /// the connection reports an error.
    private func call(
        _ share: Share,
        timeout: Double,
        _ body: @escaping (VaultFilesXPC, @escaping (Error?) -> Void) -> Void
    ) async throws {
        guard let manager = NSFileProviderManager(for: share.domain),
              let service = try await manager.service(named: FilesShared.serviceName, for: .rootContainer)
        else {
            throw NSFileProviderError(.providerNotFound)
        }
        let connection: NSXPCConnection = try await withCheckedThrowingContinuation { continuation in
            service.getFileProviderConnection { connection, error in
                if let connection {
                    continuation.resume(returning: connection)
                } else {
                    continuation.resume(throwing: error ?? NSFileProviderError(.providerNotFound))
                }
            }
        }
        connection.remoteObjectInterface = FilesXPCInterface.make()
        connection.resume()
        defer { connection.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            let finish: (Error?) -> Void = { error in
                guard once.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(NSFileProviderError(.serverUnreachable))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(error)
            }) as? VaultFilesXPC else {
                finish(NSFileProviderError(.providerNotFound))
                return
            }
            body(proxy, finish)
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private final class ResultBox: @unchecked Sendable {
    var value = false
}

/// Folders the app changed while Files was showing the vault; FilesBridge
/// signals them on the next flush. Thread-safe: Vault calls run detached.
final class FilesChangeLog: @unchecked Sendable {
    static let shared = FilesChangeLog()
    private let lock = NSLock()
    private var folders: Set<String> = []

    func note(_ path: String) {
        lock.lock()
        folders.insert(VaultPath.parent(path))
        lock.unlock()
    }

    func take() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let out = folders
        folders.removeAll()
        return out
    }
}
