import Foundation
import Observation

private struct AppPrefsData: Codable {
    var autoLockSeconds: TimeInterval
    var privacyScreenEnabled: Bool
    var noTraceMode: Bool
}

/// App-wide settings (PLAN.md section 6: SettingsView). Persisted under
/// Application Support alongside VaultStore's recents.json — no secrets
/// here either, but still file-protected and backup-excluded per the
/// same section-4 hygiene. Mutators are explicit methods (mirroring
/// VaultStore's style) rather than plain settable properties, so every
/// change is guaranteed to persist.
@Observable
final class AppPrefs {
    private(set) var autoLockSeconds: TimeInterval = 300
    private(set) var privacyScreenEnabled: Bool = true
    private(set) var noTraceMode: Bool = false

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VaultPony", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("prefs.json")
        excludeFromBackup(dir)
        load()
    }

    func setAutoLockSeconds(_ seconds: TimeInterval) {
        autoLockSeconds = seconds
        save()
    }

    func setPrivacyScreenEnabled(_ enabled: Bool) {
        privacyScreenEnabled = enabled
        save()
    }

    func setNoTraceMode(_ enabled: Bool) {
        noTraceMode = enabled
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppPrefsData.self, from: data) else { return }
        autoLockSeconds = decoded.autoLockSeconds
        privacyScreenEnabled = decoded.privacyScreenEnabled
        noTraceMode = decoded.noTraceMode
    }

    private func save() {
        let payload = AppPrefsData(autoLockSeconds: autoLockSeconds, privacyScreenEnabled: privacyScreenEnabled, noTraceMode: noTraceMode)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
