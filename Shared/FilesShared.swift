import CryptoKit
import FileProvider
import Foundation

/// Files access on iOS (2.0.0 rc3, plan D18 to D20): what the app and its
/// File Provider extension share. Compiled into both targets.
///
/// The app unlocks a vault, adds a File Provider domain with a random id and
/// a generic name, and hands the extension the session's key handoff blob
/// plus its own fd to the container over the restricted XPC service below.
/// Keys live only in the two processes' memory. Nothing about a vault is
/// written to the app group except materialized files (deleted at lock) and
/// the gate file (a counter and three timestamps).
enum FilesShared {
    static let appGroup = "group.dev.norsehorse.vaultpony"
    static let serviceName = NSFileProviderServiceName("dev.norsehorse.vaultpony.files")
    /// Posted by the app when it locks. No payload; reaches a running
    /// extension even if the XPC call didn't.
    static let lockNotification = "dev.norsehorse.vaultpony.files-lock"
    /// Every domain shows under this name in Files > Locations, whatever the
    /// vault is called, and for hidden and outer volumes alike.
    static let domainDisplayName = "VaultPony"

    static var groupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Where the system keeps each domain's materialized files.
    static func domainStorage(_ domain: NSFileProviderDomain) -> URL {
        NSFileProviderManager.default.documentStorageURL
            .appendingPathComponent(domain.pathRelativeToDocumentStorage, isDirectory: true)
    }
}

// MARK: - Time

/// A clock both processes read the same way, that keeps counting while the
/// device sleeps (Darwin's CLOCK_MONOTONIC), in nanoseconds since boot.
enum FilesClock {
    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    static func seconds(_ s: Double) -> UInt64 {
        UInt64(max(s, 0) * 1_000_000_000)
    }
}

// MARK: - Auto-lock policy (D19)

/// Sent with each handoff. The extension enforces it on its own, because the
/// app is usually suspended while Files is in use.
struct FilesPolicy: Codable, Equatable {
    /// The user's auto-lock delay, in seconds. 0 is "Immediately".
    var delaySeconds: Double
    /// Whether the volume accepts writes (false for NTFS, and after hidden
    /// volume protection tripped).
    var writable: Bool

    /// With "Immediately", Files activity still needs a window to happen in:
    /// the vault stays open until this long after the later of leaving the
    /// app and the last Files activity.
    static let immediateIdleSeconds: Double = 120
    /// Never more than this after the app was last in front (D5, D19).
    static let capSeconds: Double = 3600

    var idleSeconds: Double {
        delaySeconds > 0 ? delaySeconds : Self.immediateIdleSeconds
    }

    /// True when the vault should lock. `leftApp` is when the app last went
    /// to the background (nil while it is in front), `lastActivity` the last
    /// Files activity, both FilesClock values.
    func expired(now: UInt64, leftApp: UInt64?, lastActivity: UInt64) -> Bool {
        guard let leftApp else { return false }
        let base = max(leftApp, lastActivity)
        if now >= base &+ FilesClock.seconds(idleSeconds) { return true }
        if now >= leftApp &+ FilesClock.seconds(Self.capSeconds) { return true }
        return false
    }

    /// When `expired` turns true, for timers.
    func deadline(leftApp: UInt64, lastActivity: UInt64) -> UInt64 {
        min(max(leftApp, lastActivity) &+ FilesClock.seconds(idleSeconds),
            leftApp &+ FilesClock.seconds(Self.capSeconds))
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> FilesPolicy? {
        try? JSONDecoder().decode(FilesPolicy.self, from: data)
    }
}

// MARK: - Temporary names

/// Files edits are written beside the target under a temporary name and
/// swapped in when complete, so a killed extension never leaves a half
/// written file under the real name. These names never match the app's own
/// import names (`TransferNaming`), so neither side deletes the other's work
/// in progress, and both are hidden from every listing.
enum FilesNaming {
    static let prefix = ".vaultpony-fp-"
    static let writingSuffix = ".vpwrite"
    static let doneSuffix = ".vpdone"
    /// VFAT and exFAT allow 255 UTF-16 units per name.
    static let maxNameUnits = 255

    /// "<prefix><8 hex>~<target><suffix>", or without the target when that
    /// would be too long (no recovery is possible for those).
    static func tempName(for target: String, done: Bool) -> (name: String, carriesTarget: Bool) {
        let token = UUID().uuidString.prefix(8).lowercased()
        let suffix = done ? doneSuffix : writingSuffix
        let full = prefix + token + "~" + target + suffix
        if full.utf16.count <= maxNameUnits {
            return (full, true)
        }
        return (prefix + token + suffix, false)
    }

    /// The `.vpdone` name for a finished `.vpwrite` file.
    static func doneName(forWriting name: String) -> String {
        String(name.dropLast(writingSuffix.count)) + doneSuffix
    }

    static func isFilesTemp(_ name: String) -> Bool {
        name.hasPrefix(prefix) && (name.hasSuffix(writingSuffix) || name.hasSuffix(doneSuffix))
    }

    static func isDone(_ name: String) -> Bool {
        name.hasPrefix(prefix) && name.hasSuffix(doneSuffix)
    }

    /// The target a temp name was written for, if it carries one.
    static func target(of name: String) -> String? {
        guard isFilesTemp(name) else { return nil }
        let body = name.dropFirst(prefix.count)
        guard let tilde = body.firstIndex(of: "~") else { return nil }
        let rest = body[body.index(after: tilde)...]
        let suffix = name.hasSuffix(doneSuffix) ? doneSuffix : writingSuffix
        guard rest.count > suffix.count else { return nil }
        return String(rest.dropLast(suffix.count))
    }

    /// Names neither the app's browser nor Files should show: these temp
    /// files and the app's own import temp files.
    static func isHiddenFromListing(_ name: String) -> Bool {
        if isFilesTemp(name) { return true }
        return name.hasPrefix(".vaultpony-") && name.hasSuffix(".part")
    }
}

// MARK: - Item identifiers

/// Item identifiers for vault paths. Derived from a key minted at every
/// unlock (like Android's D14 tokens): stable while the vault is unlocked,
/// even across an extension restart, and meaningless after lock. They never
/// contain a readable name, so nothing Files stores names a vault's content.
struct ItemIDCodec {
    private let encKey: SymmetricKey
    private let nonceKey: SymmetricKey

    init(key: Data) {
        let master = SymmetricKey(data: key)
        encKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("vaultpony item id enc".utf8), outputByteCount: 32)
        nonceKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("vaultpony item id nonce".utf8), outputByteCount: 32)
    }

    static func randomKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    func identifier(for path: String) -> NSFileProviderItemIdentifier {
        if path == "/" { return .rootContainer }
        let plain = Data(path.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: plain, using: nonceKey)
        let nonceBytes = Data(mac).prefix(12)
        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes),
              let sealed = try? AES.GCM.seal(plain, using: encKey, nonce: nonce),
              let combined = sealed.combined
        else {
            return NSFileProviderItemIdentifier("invalid")
        }
        return NSFileProviderItemIdentifier("v1." + combined.base64URL())
    }

    /// The vault path for an identifier, or nil if it wasn't minted with
    /// this unlock's key.
    func path(for identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer { return "/" }
        let raw = identifier.rawValue
        guard raw.hasPrefix("v1."), let combined = Data(base64URL: String(raw.dropFirst(3))),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: encKey),
              let path = String(data: plain, encoding: .utf8)
        else { return nil }
        return path
    }
}

extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}

// MARK: - Vault paths

enum VaultPath {
    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

// MARK: - XPC

/// The extension's service. The source sets `isRestricted`, so only
/// VaultPony itself may connect, and every call also carries a token the app
/// writes to the app group per share (`FilesToken`), which other apps can't
/// read.
@objc protocol VaultFilesXPC {
    /// Hand over an unlocked vault. `blob` is the core's key handoff,
    /// `container` the app's own fd to the container (the extension dup's
    /// it), `idKey` the item-identifier key for this unlock, `policy` a
    /// JSON `FilesPolicy`. Replies nil on success. Repeating it for a vault
    /// the extension already holds only refreshes the policy.
    func adopt(_ blob: Data, container: FileHandle, idKey: Data, policy: Data, token: Data, reply: @escaping (NSError?) -> Void)

    /// Lock now: store waiting saves, then wipe keys and every materialized
    /// file. Replies when done.
    func lock(token: Data, reply: @escaping () -> Void)

    /// Whether the extension currently holds the vault.
    func status(token: Data, reply: @escaping (Bool) -> Void)
}

/// A random value per share in the app group. Holds nothing about a vault;
/// it only proves an XPC caller is VaultPony.
enum FilesToken {
    private static var url: URL? {
        FilesShared.groupContainer?.appendingPathComponent("files-token")
    }

    /// The app, when it shares a vault.
    static func mint() throws -> Data {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let token = ItemIDCodec.randomKey()
        try token.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return token
    }

    static func clear() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// The extension, on every call.
    static func matches(_ presented: Data) -> Bool {
        guard let url, let stored = try? Data(contentsOf: url), stored.count == 32, presented.count == 32 else {
            return false
        }
        var diff: UInt8 = 0
        for (a, b) in zip(stored, presented) { diff |= a ^ b }
        return diff == 0
    }
}
