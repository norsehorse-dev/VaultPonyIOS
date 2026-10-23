import Foundation

/// One writer at a time for a vault that both the app and its File Provider
/// extension have open (2.0.0 rc3). Each process holds its own mount of the
/// same volume, and each caches allocation state, so:
///
/// - every core call on a shared session runs under an exclusive `flock` on
///   a small file in the app group;
/// - the file holds a generation counter, bumped (after a flush) by every
///   call that wrote;
/// - before a call, a process whose last seen generation is older remounts
///   its session, discarding its cached state.
///
/// The lock is held for one core call only, never across a suspension (a
/// suspended process holding a file lock in a shared container is killed
/// with 0xdead10cc).
///
/// The same file carries the auto-lock clock (D19): when the app last left
/// the foreground (0 while it is in front), a heartbeat the app writes while
/// in front (so an app that crashed in front still starts the clock), and
/// when Files was last used. It also carries a read-only bit: hidden volume
/// protection latches per session, so whichever process trips it sets the
/// bit and both stop writing. Counter, times and that bit only; nothing
/// about any vault.
final class FilesGate: @unchecked Sendable {
    static let shared = FilesGate()

    struct Times {
        /// When the app last went to the background; nil while in front.
        var leftApp: UInt64?
        var lastActivity: UInt64
    }

    private let mutex = NSLock()
    private var fd: Int32 = -1
    private var lastSeen: [ObjectIdentifier: UInt64] = [:]

    private static let magic: UInt32 = 0x3147_5056 // "VPG1"
    private static let size = 48
    private static let flagReadOnly: UInt64 = 1
    /// An app in front writes a heartbeat at least this often...
    static let heartbeatSeconds: Double = 30
    /// ...so one silent for longer than this is treated as gone since its
    /// last heartbeat.
    static let heartbeatStaleSeconds: Double = 90

    // MARK: Sessions

    /// Start gating `session`: it is (or is about to be) open in both
    /// processes. Its mount is current as of now.
    func register(_ session: VaultSession) {
        mutex.lock()
        defer { mutex.unlock() }
        let gen = (try? withFileLocked { $0.generation }) ?? 0
        lastSeen[ObjectIdentifier(session)] = gen
    }

    /// The extension's side of `register`: opens the volume (`mount` runs
    /// the core import) under the gate, so no write from the app can land
    /// between reading the volume and recording the generation it saw.
    func mount(_ mount: () throws -> VaultSession) throws -> VaultSession {
        mutex.lock()
        defer { mutex.unlock() }
        return try withFileLocked { header in
            let session = try mount()
            lastSeen[ObjectIdentifier(session)] = header.generation
            return session
        }
    }

    /// A new share starts with a clean slate: no Files activity yet and
    /// no read-only bit left over from an earlier vault.
    func resetForNewShare() {
        mutex.lock()
        defer { mutex.unlock() }
        _ = try? withFileLocked { header in
            header.lastActivity = 0
            header.flags = 0
        }
    }

    /// Hidden volume protection tripped in either process.
    func isReadOnly() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return ((try? withFileLocked { $0.flags }) ?? 0) & Self.flagReadOnly != 0
    }

    func unregister(_ session: VaultSession) {
        mutex.lock()
        lastSeen[ObjectIdentifier(session)] = nil
        mutex.unlock()
    }

    func isShared(_ session: VaultSession) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return lastSeen[ObjectIdentifier(session)] != nil
    }

    /// Runs one core call on `session`. A no-op wrapper for sessions that
    /// aren't shared. `write` flushes afterwards and tells the other process
    /// to remount; `activity` records Files use for the auto-lock clock.
    func perform<T>(_ session: VaultSession, write: Bool, activity: Bool = false, _ body: () throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        let key = ObjectIdentifier(session)
        guard let seen = lastSeen[key] else {
            return try body()
        }
        return try withFileLocked { header in
            if header.generation != seen {
                try session.remount()
                lastSeen[key] = header.generation
            }
            if write, header.flags & Self.flagReadOnly != 0 {
                throw VaultError.HiddenVolumeProtected
            }
            if activity {
                header.lastActivity = FilesClock.now()
            }
            let result = Result<T, Error>(catching: { try body() })
            if case .failure(let error) = result, case .HiddenVolumeProtected? = error as? VaultError {
                header.flags |= Self.flagReadOnly
            }
            if write {
                // Even a failed write may have changed the volume.
                try? session.flush()
                header.generation &+= 1
            }
            lastSeen[key] = header.generation
            return try result.get()
        }
    }

    /// The current generation, as a change token for Files enumerations.
    func generation() -> UInt64 {
        mutex.lock()
        defer { mutex.unlock() }
        return (try? withFileLocked { $0.generation }) ?? 0
    }

    // MARK: Auto-lock clock

    func times() -> Times {
        mutex.lock()
        defer { mutex.unlock() }
        guard let header = try? withFileLocked({ $0 }) else {
            // No gate file: treat the app as gone long ago, so the extension
            // locks rather than holding keys with no clock.
            return Times(leftApp: 1, lastActivity: 0)
        }
        if header.leftApp != 0 {
            return Times(leftApp: header.leftApp, lastActivity: header.lastActivity)
        }
        // "In front", but only as long as the heartbeat is fresh.
        let now = FilesClock.now()
        if now > header.heartbeat &+ FilesClock.seconds(Self.heartbeatStaleSeconds) {
            return Times(leftApp: max(header.heartbeat, 1), lastActivity: header.lastActivity)
        }
        return Times(leftApp: nil, lastActivity: header.lastActivity)
    }

    /// The app records leaving (a time) and returning (nil). Returning also
    /// writes a heartbeat.
    func setLeftApp(_ time: UInt64?) {
        mutex.lock()
        defer { mutex.unlock() }
        _ = try? withFileLocked { header in
            header.leftApp = time ?? 0
            if time == nil {
                header.heartbeat = FilesClock.now()
            }
        }
    }

    /// The app is still in front.
    func heartbeat() {
        mutex.lock()
        defer { mutex.unlock() }
        _ = try? withFileLocked { header in
            header.heartbeat = FilesClock.now()
        }
    }

    /// Records Files use without a core call (the extension's own entry
    /// points that don't touch the volume).
    func noteActivity() {
        mutex.lock()
        defer { mutex.unlock() }
        _ = try? withFileLocked { header in
            header.lastActivity = FilesClock.now()
        }
    }

    // MARK: File

    private struct Header: Equatable {
        var generation: UInt64 = 0
        var lastActivity: UInt64 = 0
        var leftApp: UInt64 = 0
        var heartbeat: UInt64 = 0
        var flags: UInt64 = 0
    }

    private enum GateError: Error {
        case unavailable
        case io(Int32)
    }

    /// Caller holds `mutex`.
    private func withFileLocked<T>(_ body: (inout Header) throws -> T) throws -> T {
        let fd = try openFile()
        guard flock(fd, LOCK_EX) == 0 else { throw GateError.io(errno) }
        defer { flock(fd, LOCK_UN) }
        var header = try read(fd)
        let before = header
        let result = try body(&header)
        if header != before {
            try write(header, fd)
        }
        return result
    }

    private func openFile() throws -> Int32 {
        if fd >= 0 { return fd }
        guard let dir = FilesShared.groupContainer else { throw GateError.unavailable }
        let url = dir.appendingPathComponent("files-gate")
        let opened = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDWR | O_CREAT, 0o600)
        }
        guard opened >= 0 else { throw GateError.io(errno) }
        // Only a counter and times: readable after first unlock, so a Files
        // operation that races the device locking doesn't fail on the gate.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        fd = opened
        return opened
    }

    private func read(_ fd: Int32) throws -> Header {
        var buf = [UInt8](repeating: 0, count: Self.size)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Self.size, 0) }
        guard n == Self.size else { return Header() }
        func u64(_ at: Int) -> UInt64 {
            buf[at..<at + 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }
        let magic = UInt32(buf[0]) | UInt32(buf[1]) << 8 | UInt32(buf[2]) << 16 | UInt32(buf[3]) << 24
        guard magic == Self.magic else { return Header() }
        var header = Header(generation: u64(8), lastActivity: u64(16), leftApp: u64(24), heartbeat: u64(32), flags: u64(40))
        // The clock restarts at boot and this file doesn't: a time from
        // before a reboot is later than now and would hold the vault open.
        let now = FilesClock.now()
        if header.lastActivity > now { header.lastActivity = 0 }
        if header.leftApp > now { header.leftApp = 1 }
        if header.heartbeat > now { header.heartbeat = 0 }
        return header
    }

    private func write(_ header: Header, _ fd: Int32) throws {
        var buf = [UInt8](repeating: 0, count: Self.size)
        func put(_ v: UInt64, _ at: Int) {
            for i in 0..<8 { buf[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
        }
        let m = Self.magic
        buf[0] = UInt8(truncatingIfNeeded: m)
        buf[1] = UInt8(truncatingIfNeeded: m >> 8)
        buf[2] = UInt8(truncatingIfNeeded: m >> 16)
        buf[3] = UInt8(truncatingIfNeeded: m >> 24)
        put(header.generation, 8)
        put(header.lastActivity, 16)
        put(header.leftApp, 24)
        put(header.heartbeat, 32)
        put(header.flags, 40)
        let n = buf.withUnsafeBytes { pwrite(fd, $0.baseAddress, Self.size, 0) }
        guard n == Self.size else { throw GateError.io(errno) }
    }
}
