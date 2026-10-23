import FileProvider
import Foundation
import os

/// One domain's vault inside the extension: the session the app handed over,
/// the item-id key, the auto-lock policy, and the materialized files. Keys
/// live only here, in memory (THREAT_MODEL-IOS section 9).
///
/// Every core call goes through `FilesGate`, which serializes it against the
/// app and remounts when the app wrote in between. Entry points check the
/// auto-lock deadline first; past it, the vault locks itself and Files sees
/// `notAuthenticated` ("Open VaultPony"). Locking first stores any edit
/// another app saved but that hasn't reached the vault yet.
final class FilesVault: @unchecked Sendable {
    let domainID: String
    let storage: URL

    private let lock = NSLock()
    private var session: VaultSession?
    private var codec: ItemIDCodec?
    private var policy = FilesPolicy(delaySeconds: 0, writable: false)
    private var timer: DispatchSourceTimer?
    /// Set while `lockNow` stores the last edits: those calls skip the
    /// deadline check that triggered the lock.
    private var locking = false
    /// While locking: stores give up (leaving the original untouched) once
    /// this passes, so a large save can't keep the keys alive.
    private var storeDeadline: Date?
    /// Vault (size, mtime) of each file when Files last got it, by vault
    /// path: an edit from Files over a file that changed in the vault since
    /// is kept beside it instead (D6).
    private var snapshots: [String: Snapshot] = [:]
    /// What was written out where, by local path, to spot saves that never
    /// reached the vault.
    private var materialized: [String: Materialized] = [:]
    /// After a keep-both, later saves of the same document go to the copy,
    /// not to yet another "name (n)". Original vault path to the copy's path.
    private var redirects: [String: String] = [:]
    /// Temp names this process is writing right now (vault paths).
    private var inFlight: Set<String> = []
    /// Saves waiting out their one-second burst window, by local path.
    private var pendingEdits: [String: DispatchWorkItem] = [:]
    /// One store at a time. Recursive: a store that hits the deadline locks,
    /// and locking stores what is left on the same thread.
    private let storeLock = NSRecursiveLock()
    /// Writing a file out and deleting it run here, in order, so a quick
    /// close and reopen can't have the delete land after the new write-out.
    let fileQueue = DispatchQueue(label: "dev.norsehorse.vaultpony.FileProvider.files")
    /// Stores run one at a time, off the calling thread.
    private let storeQueue = DispatchQueue(label: "dev.norsehorse.vaultpony.FileProvider.stores")
    private var service: FilesServiceSource?

    private static let log = Logger(subsystem: "dev.norsehorse.vaultpony.FileProvider", category: "vault")
    static let chunk: UInt32 = 256 * 1024
    /// How long a lock may spend storing edits before the keys go.
    private static let lockStoreBudget: TimeInterval = 10

    struct Snapshot: Equatable {
        var size: UInt64
        var mtime: Int64?
    }

    private struct Materialized {
        var url: URL
        var path: String
        var localSize: UInt64
        var localDate: Date?
    }

    // MARK: Registry

    private static let registryLock = NSLock()
    private static var registry: [String: FilesVault] = [:]

    static func forDomain(_ domain: NSFileProviderDomain) -> FilesVault {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[domain.identifier.rawValue] {
            return existing
        }
        let vault = FilesVault(domainID: domain.identifier.rawValue, storage: FilesShared.domainStorage(domain))
        registry[domain.identifier.rawValue] = vault
        return vault
    }

    static func lockAll() {
        registryLock.lock()
        let all = Array(registry.values)
        registryLock.unlock()
        all.forEach { $0.lockNow() }
    }

    private init(domainID: String, storage: URL) {
        self.domainID = domainID
        self.storage = storage
        // A new process has no keys, so anything left on disk is plaintext
        // from a process that died before it could clean up. (A save that
        // process never stored is lost with it; THREAT_MODEL-IOS section 9.)
        wipeStorage()
        DarwinLockListener.install()
    }

    /// The XPC service, kept alive with the vault so its listener outlives
    /// the call that created it.
    func serviceSource() -> FilesServiceSource {
        lock.lock()
        defer { lock.unlock() }
        if let service { return service }
        let made = FilesServiceSource(vault: self)
        service = made
        return made
    }

    // MARK: Handoff

    func adopt(blob: Data, container: FileHandle, idKey: Data, policyData: Data) throws {
        guard let policy = FilesPolicy.decode(policyData) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        }
        lock.lock()
        defer { lock.unlock() }
        if locking {
            // Locking right now: the app must hand the vault over again.
            throw NSFileProviderError(.notAuthenticated)
        }
        if session != nil {
            // Already holding it: the app re-pushes on every return to the
            // foreground. Only the policy changes, and never back to
            // writable once this side found the volume read-only.
            self.policy = FilesPolicy(delaySeconds: policy.delaySeconds, writable: policy.writable && self.policy.writable)
            return
        }
        let fd = dup(container.fileDescriptor)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // The session takes ownership of fd and closes it on lock. Mounted
        // under the gate, so no app write slips in before it is registered.
        let opened = try FilesGate.shared.mount {
            try VaultSession.importHandoffFd(fd: fd, blob: blob)
        }
        self.policy = policy
        session = opened
        codec = ItemIDCodec(key: idKey)
        locking = false
        startTimer()
        Self.log.info("vault adopted")
    }

    var isOpen: Bool {
        (try? open()) != nil
    }

    var isWritable: Bool {
        lock.lock()
        let writable = policy.writable
        lock.unlock()
        return writable && !FilesGate.shared.isReadOnly()
    }

    func requireWritable() throws {
        guard isWritable else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
        }
    }

    /// Store pending and unnoticed saves (within a time budget), then
    /// zeroize the keys, close the container, delete every materialized file.
    func lockNow() {
        lock.lock()
        if locking {
            // Already locking on another thread: wait for it, so whoever
            // asked (the app's XPC lock) hears back only once it's done.
            lock.unlock()
            let giveUp = Date().addingTimeInterval(Self.lockStoreBudget + 5)
            while Date() < giveUp {
                lock.lock()
                let still = locking
                lock.unlock()
                if !still { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return
        }
        guard session != nil else {
            lock.unlock()
            wipeStorage()
            return
        }
        locking = true
        lock.unlock()

        storeChangedFiles(deadline: Date().addingTimeInterval(Self.lockStoreBudget))
        // Past the budget a store in progress stops at its next chunk.
        lock.lock()
        storeDeadline = nil
        lock.unlock()

        lock.lock()
        let closing = session
        session = nil
        codec = nil
        snapshots.removeAll()
        materialized.removeAll()
        redirects.removeAll()
        inFlight.removeAll()
        timer?.cancel()
        timer = nil
        locking = false
        lock.unlock()
        if let closing {
            _ = try? FilesGate.shared.perform(closing, write: false) { try closing.flush() }
            FilesGate.shared.unregister(closing)
            closing.lock()
        }
        wipeStorage()
        Self.log.info("vault locked")
        signal(.rootContainer)
    }

    /// The open session and codec, after the auto-lock check. Throws
    /// `notAuthenticated` when locked or past the deadline.
    func open() throws -> (VaultSession, ItemIDCodec) {
        lock.lock()
        guard let session, let codec else {
            lock.unlock()
            throw NSFileProviderError(.notAuthenticated)
        }
        let policy = self.policy
        let locking = self.locking
        lock.unlock()
        if !locking {
            let times = FilesGate.shared.times()
            if policy.expired(now: FilesClock.now(), leftApp: times.leftApp, lastActivity: times.lastActivity) {
                lockNow()
                throw NSFileProviderError(.notAuthenticated)
            }
        }
        return (session, codec)
    }

    func codecIfOpen() -> ItemIDCodec? {
        lock.lock()
        defer { lock.unlock() }
        return codec
    }

    /// While the process runs (it doesn't while suspended), check the
    /// deadline every 15 seconds.
    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            _ = try? self.open()
        }
        t.resume()
        timer = t
    }

    // MARK: Core calls

    /// One gated core call. `activity` (user-driven calls) keeps the vault
    /// open under the auto-lock rule; the system's own lookups don't.
    func call<T>(write: Bool = false, activity: Bool = true, _ body: (VaultSession) throws -> T) throws -> T {
        let (session, _) = try open()
        lock.lock()
        // Stores made while locking are not Files activity: they must not
        // push the auto-lock back.
        let counts = activity && !locking
        lock.unlock()
        do {
            return try FilesGate.shared.perform(session, write: write, activity: counts) {
                try body(session)
            }
        } catch let error as VaultError {
            if case .HiddenVolumeProtected = error {
                lock.lock()
                policy.writable = false
                lock.unlock()
                signal(.rootContainer)
            }
            throw Self.map(error)
        }
    }

    /// A missing path is `noSuchItem`; a locked vault stays `notAuthenticated`.
    func stat(_ path: String, activity: Bool = true) throws -> DirEntry {
        do {
            return try call(activity: activity) { try $0.stat(path: path) }
        } catch let error as NSFileProviderError where error.code == .notAuthenticated {
            throw error
        } catch {
            throw NSError.fileProviderErrorForNonExistentItem(withIdentifier: try identifier(for: path))
        }
    }

    /// Whether `path` exists, from its folder's listing (case-insensitive,
    /// as on FAT and exFAT). Errors other than "not there" are thrown, so a
    /// failed lookup never reads as "free to write".
    func exists(_ path: String) throws -> Bool {
        let name = VaultPath.name(path).lowercased()
        return try call { try $0.list(path: VaultPath.parent(path)) }.contains { $0.name.lowercased() == name }
    }

    func identifier(for path: String) throws -> NSFileProviderItemIdentifier {
        let (_, codec) = try open()
        return codec.identifier(for: path)
    }

    func path(for identifier: NSFileProviderItemIdentifier) throws -> String {
        let (_, codec) = try open()
        guard let path = codec.path(for: identifier) else {
            throw NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)
        }
        return path
    }

    func item(for path: String) throws -> FileProviderItem {
        let (_, codec) = try open()
        if path == "/" {
            return FileProviderItem.root(writable: isWritable)
        }
        let entry = try stat(path, activity: false)
        return FileProviderItem(path: path, entry: entry, codec: codec, writable: isWritable)
    }

    /// Children of a folder, minus temp files. Finishes or clears temp files
    /// left by a process that was killed mid-save on the way.
    func list(_ folder: String) throws -> [DirEntry] {
        let entries = try call { try $0.list(path: folder) }
        if isWritable {
            recoverTemps(in: folder, entries: entries)
        }
        return entries.filter { !FilesNaming.isHiddenFromListing($0.name) }
    }

    // MARK: Materializing

    /// Writes the vault file out to `url` (`.complete` protection, excluded
    /// from backup) unless an up-to-date copy is already there.
    func materialize(path: String, to url: URL) throws {
        let entry = try call { try $0.stat(path: path) }
        let snap = Snapshot(size: entry.size, mtime: entry.mtimeMs)
        lock.lock()
        let current = snapshots[path]
        let known = materialized[Self.key(url)] != nil
        lock.unlock()
        if current == snap, known, FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try makeDirectory(url.deletingLastPathComponent())
        let partial = url.deletingLastPathComponent().appendingPathComponent(".vp-materializing")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        let out = try FileHandle(forWritingTo: partial)
        do {
            var offset: UInt64 = 0
            while true {
                let data = try call { try $0.readAt(path: path, offset: offset, len: Self.chunk) }
                if data.isEmpty { break }
                try out.write(contentsOf: data)
                offset += UInt64(data.count)
                if data.count < Int(Self.chunk) { break }
            }
            try out.close()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        let local = Self.localState(url)
        lock.lock()
        snapshots[path] = snap
        materialized[Self.key(url)] = Materialized(url: url, path: path, localSize: local.size, localDate: local.date)
        lock.unlock()
    }

    /// No one uses the materialized copy any more: store a save still
    /// waiting, then delete the file (the placeholder and folders stay).
    func dematerialize(url: URL) {
        lock.lock()
        pendingEdits.removeValue(forKey: Self.key(url))?.cancel()
        lock.unlock()
        storeIfChanged(url: url)
        try? FileManager.default.removeItem(at: url)
        lock.lock()
        materialized[Self.key(url)] = nil
        lock.unlock()
    }

    // MARK: Saves from other apps

    /// Another app saved `url`. Saves come in bursts, so this waits a second
    /// for the last one.
    func scheduleEdit(url: URL) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingEdits[Self.key(url)] = nil
            self.lock.unlock()
            self.storeIfChanged(url: url)
        }
        lock.lock()
        pendingEdits.updateValue(work, forKey: Self.key(url))?.cancel()
        lock.unlock()
        storeQueue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Stores `url` into the vault if its local copy changed since it was
    /// written out or last stored.
    private func storeIfChanged(url: URL) {
        storeLock.lock()
        defer { storeLock.unlock() }
        lock.lock()
        let entry = materialized[Self.key(url)]
        lock.unlock()
        guard let entry else { return }
        let local = Self.localState(url)
        guard FileManager.default.fileExists(atPath: url.path),
              local.size != entry.localSize || local.date != entry.localDate
        else { return }
        storeEdit(entry, local: local)
    }

    private func storeEdit(_ entry: Materialized, local: (size: UInt64, date: Date?)) {
        lock.lock()
        let target = redirects[entry.path] ?? entry.path
        lock.unlock()
        var stored: String?
        do {
            stored = try store(localFile: entry.url, at: target, replacing: true, keepBothIfChanged: true)
        } catch {
            // The folder was renamed or removed meanwhile, or the write was
            // refused: keep the content as a copy at the top level rather
            // than drop it.
            Self.log.error("a save could not be stored in place")
            if let fallback = try? uniqueName(VaultPath.name(target), in: "/") {
                stored = try? store(localFile: entry.url, at: VaultPath.join("/", fallback), replacing: false)
            }
        }
        guard let stored else {
            Self.log.error("a save could not be stored")
            return
        }
        if stored != target {
            lock.lock()
            redirects[entry.path] = stored
            lock.unlock()
        }
        noteStored(path: stored)
        lock.lock()
        materialized[Self.key(entry.url)]?.localSize = local.size
        materialized[Self.key(entry.url)]?.localDate = local.date
        lock.unlock()
        if let parent = try? identifier(for: VaultPath.parent(stored)) {
            signal(parent)
        }
    }

    /// At lock: every save still waiting or never announced goes in first.
    private func storeChangedFiles(deadline: Date) {
        lock.lock()
        storeDeadline = deadline
        pendingEdits.values.forEach { $0.cancel() }
        pendingEdits.removeAll()
        let urls = materialized.values.map(\.url)
        lock.unlock()
        for url in urls {
            if Date() > deadline {
                Self.log.error("lock ran out of time storing saves")
                break
            }
            storeIfChanged(url: url)
        }
    }

    /// One spelling per file (/var and /private/var are the same place).
    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func localState(_ url: URL) -> (size: UInt64, date: Date?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (UInt64(values?.fileSize ?? 0), values?.contentModificationDate)
    }

    // MARK: Writing

    /// Streams a local file into the vault at `target`, through a temp name
    /// that is swapped in only when complete. Returns the final vault path.
    /// With `keepBothIfChanged`, an existing target that changed in the vault
    /// since Files got it is left alone and the new content lands beside it
    /// as "name (1)". With `replacing` false, an existing name always gets
    /// the "name (1)" treatment.
    @discardableResult
    func store(localFile url: URL, at target: String, replacing: Bool, keepBothIfChanged: Bool = false) throws -> String {
        try requireWritable()
        let folder = VaultPath.parent(target)
        var finalPath = target
        if try exists(target) {
            var keepBoth = !replacing
            if keepBothIfChanged {
                let entry = try call { try $0.stat(path: target) }
                lock.lock()
                let snap = snapshots[target]
                lock.unlock()
                if let snap, snap != Snapshot(size: entry.size, mtime: entry.mtimeMs) {
                    keepBoth = true
                }
            }
            if keepBoth {
                finalPath = VaultPath.join(folder, try uniqueName(VaultPath.name(target), in: folder))
            }
        }
        let finalName = VaultPath.name(finalPath)
        let (writingName, carriesTarget) = FilesNaming.tempName(for: finalName, done: false)
        let writingPath = VaultPath.join(folder, writingName)

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        lock.lock()
        inFlight.insert(writingPath)
        lock.unlock()
        defer {
            lock.lock()
            inFlight.remove(writingPath)
            lock.unlock()
        }
        do {
            try call(write: true) { try $0.create(path: writingPath) }
            var offset: UInt64 = 0
            while true {
                lock.lock()
                let deadline = storeDeadline
                lock.unlock()
                if let deadline, Date() > deadline {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                }
                let data = try autoreleasepool { try input.read(upToCount: Int(Self.chunk)) } ?? Data()
                if data.isEmpty { break }
                try call(write: true) { _ = try $0.writeAt(path: writingPath, offset: offset, data: data) }
                offset += UInt64(data.count)
            }
            // One gated call for the swap, so the app never lists the
            // moment the target is gone and the new file not yet in place.
            if carriesTarget {
                let donePath = VaultPath.join(folder, FilesNaming.doneName(forWriting: writingName))
                try call(write: true) { s in
                    try s.rename(from: writingPath, to: donePath)
                    try s.replace(src: donePath, dst: finalPath)
                }
            } else {
                try call(write: true) { try $0.replace(src: writingPath, dst: finalPath) }
            }
        } catch {
            _ = try? call(write: true) { try $0.remove(path: writingPath) }
            throw error
        }
        return finalPath
    }

    /// Records what Files now holds for `path` (after an edit was stored).
    func noteStored(path: String) {
        guard let entry = try? call({ try $0.stat(path: path) }) else { return }
        lock.lock()
        snapshots[path] = Snapshot(size: entry.size, mtime: entry.mtimeMs)
        lock.unlock()
    }

    func uniqueName(_ name: String, in folder: String) throws -> String {
        let taken = Set(try call { try $0.list(path: folder) }.map { $0.name.lowercased() })
        if !taken.contains(name.lowercased()) { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let plain = ext.isEmpty || name.hasPrefix(".")
        let base = plain ? name : ns.deletingPathExtension
        for n in 1...9999 {
            let candidate = plain ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
    }

    /// Deletes a file, or a folder and everything in it.
    func removeTree(_ path: String) throws {
        try requireWritable()
        let entry = try call { try $0.stat(path: path) }
        if entry.isDir {
            for child in try call({ try $0.list(path: path) }) {
                try removeTree(VaultPath.join(path, child.name))
            }
        }
        try call(write: true) { try $0.remove(path: path) }
    }

    /// `.vpdone` files are complete: finish their swap. `.vpwrite` files not
    /// being written by this process were cut off: delete them.
    private func recoverTemps(in folder: String, entries: [DirEntry]) {
        for entry in entries where !entry.isDir && FilesNaming.isFilesTemp(entry.name) {
            let tempPath = VaultPath.join(folder, entry.name)
            let writingTwin = VaultPath.join(folder, entry.name.replacingOccurrences(of: FilesNaming.doneSuffix, with: FilesNaming.writingSuffix))
            lock.lock()
            let busy = inFlight.contains(tempPath) || inFlight.contains(writingTwin)
            lock.unlock()
            if busy { continue }
            if FilesNaming.isDone(entry.name), let target = FilesNaming.target(of: entry.name) {
                _ = try? call(write: true) { try $0.replace(src: tempPath, dst: VaultPath.join(folder, target)) }
            } else {
                _ = try? call(write: true) { try $0.remove(path: tempPath) }
            }
        }
    }

    // MARK: Helpers

    func signal(_ identifier: NSFileProviderItemIdentifier) {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainID),
            displayName: FilesShared.domainDisplayName,
            pathRelativeToDocumentStorage: storage.lastPathComponent
        )
        NSFileProviderManager(for: domain)?.signalEnumerator(for: identifier) { _ in }
    }

    /// Folders under the domain storage get `.complete` too, so names in
    /// them aren't readable while the device is locked.
    func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        excludeFromBackup(storage)
    }

    private func wipeStorage() {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil) else { return }
        for child in children {
            try? fm.removeItem(at: child)
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Core errors as Files errors. Never carries a name or a path.
    static func map(_ error: VaultError) -> Error {
        switch error {
        case .HiddenVolumeProtected, .TrueCryptReadOnly:
            // TrueCrypt sessions are never writable (2.0.0 rc5); the policy
            // already says so and this is the backstop.
            return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
        case .Filesystem(let detail) where detail.localizedCaseInsensitiveContains("space") || detail.localizedCaseInsensitiveContains("full"):
            return NSFileProviderError(.insufficientQuota)
        case .Io(let detail) where detail.localizedCaseInsensitiveContains("full") || detail.localizedCaseInsensitiveContains("space"):
            return NSFileProviderError(.insufficientQuota)
        case .Internal:
            return NSFileProviderError(.notAuthenticated)
        default:
            return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
    }
}

// MARK: - Lock notification

/// The app posts a Darwin notification when it locks, in case its XPC call
/// didn't arrive. No payload: every vault in this process locks. Any app
/// can post one, which can only lock the vault early (THREAT_MODEL-IOS 9).
enum DarwinLockListener {
    private static var installed = false
    private static let lock = NSLock()

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.global(qos: .userInitiated).async { FilesVault.lockAll() }
            },
            FilesShared.lockNotification as CFString,
            nil,
            .deliverImmediately
        )
    }
}
