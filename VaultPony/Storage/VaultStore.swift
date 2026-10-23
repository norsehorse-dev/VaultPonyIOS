import Foundation
import Observation

/// A saved vault: its security-scoped bookmark plus display metadata.
/// Never holds a passphrase or a derived key (THREAT_MODEL-IOS.md section
/// 4) — bookmarkData still leaks a filename if this file were restored
/// elsewhere, which is why VaultStore excludes it from backup below. Any
/// biometric-unlock credential lives separately in the Keychain
/// (BiometricUnlock), keyed by this vault's id — not here.
struct SavedVault: Identifiable, Codable, Hashable {
    var id: UUID
    /// Empty when the vault list hides names (2.0.0 rc4); the list then
    /// shows "Vault 1", "Vault 2" and so on (`VaultStore.label(for:)`).
    var displayName: String
    var bookmarkData: Data
    var lastOpened: Date?
    var lastFilesystem: String?
    /// A hash the user picked by hand on the unlock screen, as its menu
    /// label ("SHA-512"), so the menu starts on it next time (2.0.0 rc4,
    /// D21). Never what Auto found, never from a failed unlock.
    var rememberedHash: String?
    /// TrueCrypt mode, ticked by hand on the unlock screen for a successful
    /// unlock, so the toggle starts on next time (2.0.0 rc5, plan 6.2). Kept
    /// like `rememberedHash`; nil (never set, or entries from before rc5)
    /// means off.
    var rememberedTrueCrypt: Bool?
    /// Added while the vault list keeps nothing ("Don't keep" or no-trace
    /// mode): held in memory only, never written to recents.json, and gone
    /// when the vault locks or the user goes back to the list.
    var isTransient = false

    private enum CodingKeys: String, CodingKey {
        case id, displayName, bookmarkData, lastOpened, lastFilesystem, rememberedHash, rememberedTrueCrypt
    }
}

/// Recents list, persisted to a JSON file under Application Support.
/// THREAT_MODEL-IOS.md section 4: no secrets here, but still
/// file-protected and backup-excluded.
@Observable
final class VaultStore {
    /// The app's one store. VaultPonyApp puts it in the environment;
    /// SessionRegistry.lock reaches it here (2.0.0 rc4, "Don't keep").
    static let shared = VaultStore()

    private(set) var vaults: [SavedVault] = []
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VaultPony", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("recents.json")
        excludeFromBackup(dir)
        load()
    }

    /// `mode` is the vault list setting in effect
    /// (`AppPrefs.effectiveVaultListMode`): "Hide names" stores no name,
    /// "Don't keep" keeps the entry in memory only.
    @discardableResult
    func add(bookmarkData: Data, displayName: String, mode: VaultListMode) -> SavedVault {
        let vault = SavedVault(
            id: UUID(),
            displayName: mode == .hideNames ? "" : displayName,
            bookmarkData: bookmarkData,
            lastOpened: nil,
            lastFilesystem: nil,
            rememberedHash: nil,
            rememberedTrueCrypt: nil,
            isTransient: mode == .dontKeep
        )
        vaults.insert(vault, at: 0)
        save()
        return vault
    }

    /// The name the app shows for a vault: its file name, or "Vault 1",
    /// "Vault 2" and so on (in list order) when no name is stored.
    func label(for vault: SavedVault) -> String {
        if !vault.displayName.isEmpty {
            return vault.displayName
        }
        if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
            return String(localized: "Vault \(index + 1)", locale: LanguageOverride.locale)
        }
        return String(localized: "Vault", locale: LanguageOverride.locale)
    }

    func rememberedHash(for id: UUID) -> String? {
        vaults.first { $0.id == id }?.rememberedHash
    }

    /// Stores (or with nil clears) the hash the user picked by hand.
    func setRememberedHash(_ id: UUID, hash: String?) {
        guard let index = vaults.firstIndex(where: { $0.id == id }),
              vaults[index].rememberedHash != hash else { return }
        vaults[index].rememberedHash = hash
        save()
    }

    func rememberedTrueCrypt(for id: UUID) -> Bool {
        vaults.first { $0.id == id }?.rememberedTrueCrypt == true
    }

    /// Stores TrueCrypt mode on (ticked by hand, unlock succeeded) or
    /// clears it (unticked).
    func setRememberedTrueCrypt(_ id: UUID, on: Bool) {
        let value: Bool? = on ? true : nil
        guard let index = vaults.firstIndex(where: { $0.id == id }),
              vaults[index].rememberedTrueCrypt != value else { return }
        vaults[index].rememberedTrueCrypt = value
        save()
    }

    /// "Hide names" chosen: wipes every stored display name.
    func wipeDisplayNames() {
        for index in vaults.indices {
            vaults[index].displayName = ""
        }
        save()
    }

    /// "Don't keep" chosen: every entry goes, with its Face ID unlock and
    /// remembered hash. The vault files are not touched.
    func removeAll() {
        for vault in vaults {
            BiometricUnlock.remove(vaultId: vault.id)
        }
        vaults.removeAll()
        save()
    }

    /// A vault was locked. With "Don't keep" in effect it leaves the list.
    /// Transient entries other than `unlockedId` go either way.
    func vaultLocked(_ id: UUID?, removeIt: Bool, unlockedId: UUID?) {
        if removeIt, let id, id != unlockedId, vaults.contains(where: { $0.id == id }) {
            remove(id)
        }
        pruneTransient(keeping: unlockedId)
    }

    /// Drops in-memory entries, except the vault that is unlocked now.
    func pruneTransient(keeping unlockedId: UUID?) {
        let gone = vaults.filter { $0.isTransient && $0.id != unlockedId }
        guard !gone.isEmpty else { return }
        for vault in gone {
            remove(vault.id)
        }
    }

    func touch(_ id: UUID, filesystem: String? = nil) {
        guard let index = vaults.firstIndex(where: { $0.id == id }) else { return }
        vaults[index].lastOpened = Date()
        if let filesystem {
            vaults[index].lastFilesystem = filesystem
        }
        save()
    }

    func updateBookmark(_ id: UUID, data: Data) {
        guard let index = vaults.firstIndex(where: { $0.id == id }) else { return }
        vaults[index].bookmarkData = data
        save()
    }

    /// Removes a vault from Recents and wipes any biometric credential
    /// stored for it (PLAN.md section 7 — a stored passphrase must never
    /// outlive the vault entry that references it).
    func remove(_ id: UUID) {
        BiometricUnlock.remove(vaultId: id)
        vaults.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        vaults = (try? JSONDecoder().decode([SavedVault].self, from: data)) ?? []
    }

    private func save() {
        // Transient entries ("Don't keep", no-trace mode) never reach disk.
        guard let data = try? JSONEncoder().encode(vaults.filter { !$0.isTransient }) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
