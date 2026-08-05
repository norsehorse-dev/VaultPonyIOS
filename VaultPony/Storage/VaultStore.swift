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
    var displayName: String
    var bookmarkData: Data
    var lastOpened: Date?
    var lastFilesystem: String?
}

/// Recents list, persisted to a JSON file under Application Support.
/// THREAT_MODEL-IOS.md section 4: no secrets here, but still
/// file-protected and backup-excluded.
@Observable
final class VaultStore {
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

    @discardableResult
    func add(bookmarkData: Data, displayName: String) -> SavedVault {
        let vault = SavedVault(id: UUID(), displayName: displayName, bookmarkData: bookmarkData, lastOpened: nil, lastFilesystem: nil)
        vaults.insert(vault, at: 0)
        save()
        return vault
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
        guard let data = try? JSONEncoder().encode(vaults) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
