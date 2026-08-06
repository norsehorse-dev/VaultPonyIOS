import Foundation
import Observation

private struct AppPrefsData: Codable {
    var autoLockSeconds: TimeInterval
    var privacyScreenEnabled: Bool
    var noTraceMode: Bool
    var onboardingDone: Bool
    var languageCode: String?

    init(autoLockSeconds: TimeInterval, privacyScreenEnabled: Bool, noTraceMode: Bool, onboardingDone: Bool, languageCode: String?) {
        self.autoLockSeconds = autoLockSeconds
        self.privacyScreenEnabled = privacyScreenEnabled
        self.noTraceMode = noTraceMode
        self.onboardingDone = onboardingDone
        self.languageCode = languageCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoLockSeconds = try container.decode(TimeInterval.self, forKey: .autoLockSeconds)
        privacyScreenEnabled = try container.decode(Bool.self, forKey: .privacyScreenEnabled)
        noTraceMode = try container.decode(Bool.self, forKey: .noTraceMode)
        onboardingDone = try container.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
    }
}

/// Mirrors AppPrefs' chosen language for localized-string call sites that
/// can't read SwiftUI's `\.locale` environment — error-description
/// properties on model/error types (VaultError+Localized.swift,
/// BiometricUnlock.swift, FdOpener.swift) are evaluated outside any View
/// body, so `.environment(\.locale, ...)` set at the WindowGroup doesn't
/// reach them. Kept in sync by AppPrefs on init and on every
/// `setLanguageCode` call. `nil` means "follow the system language."
enum LanguageOverride {
    private static var code: String?

    static func update(_ languageCode: String?) {
        code = languageCode
    }

    static var locale: Locale {
        code.map { Locale(identifier: $0) } ?? Locale.autoupdatingCurrent
    }
}

/// App-wide settings (PLAN.md section 6: SettingsView). Persisted under
/// Application Support alongside VaultStore's recents.json — no secrets
/// here either, but still file-protected and backup-excluded per the
/// same section-4 hygiene. Mutators are explicit methods (mirroring
/// VaultStore's style) rather than plain settable properties, so every
/// change is guaranteed to persist.
///
/// `replayOnboardingRequested` is intentionally NOT persisted — it's a
/// one-shot in-memory signal set by Settings' "Show the intro again" row
/// and cleared once the onboarding flow reads it, mirroring Android's
/// `onReplayOnboarding` callback rather than SharedPreferences state.
///
/// `languageCode` drives a live, in-app language switch (parity port of
/// VaultPonyAndroid's `LocaleManager.setLanguage`) — `nil` follows the
/// system per-app language, a concrete code (e.g. "de") pins VaultPony to
/// that language immediately, without an app restart. VaultPonyApp.swift
/// applies it via `.environment(\.locale, appPrefs.locale)`; see
/// `LanguageOverride` above for the handful of call sites outside the
/// SwiftUI view tree that need the same value threaded in manually.
@Observable
final class AppPrefs {
    private(set) var autoLockSeconds: TimeInterval = 300
    private(set) var privacyScreenEnabled: Bool = true
    private(set) var noTraceMode: Bool = false
    private(set) var onboardingDone: Bool = false
    private(set) var replayOnboardingRequested: Bool = false
    private(set) var languageCode: String?

    var locale: Locale {
        languageCode.map { Locale(identifier: $0) } ?? Locale.autoupdatingCurrent
    }

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VaultPony", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("prefs.json")
        excludeFromBackup(dir)
        load()
        LanguageOverride.update(languageCode)
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

    func setOnboardingDone(_ done: Bool) {
        onboardingDone = done
        save()
    }

    func requestReplayOnboarding() {
        replayOnboardingRequested = true
    }

    func clearReplayOnboardingRequest() {
        replayOnboardingRequested = false
    }

    /// Pass `nil` to follow the system per-app language again. Takes
    /// effect immediately across the app via the `\.locale` environment
    /// (set in VaultPonyApp.swift) and `LanguageOverride` above.
    func setLanguageCode(_ code: String?) {
        languageCode = code
        LanguageOverride.update(code)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppPrefsData.self, from: data) else { return }
        autoLockSeconds = decoded.autoLockSeconds
        privacyScreenEnabled = decoded.privacyScreenEnabled
        noTraceMode = decoded.noTraceMode
        onboardingDone = decoded.onboardingDone
        languageCode = decoded.languageCode
    }

    private func save() {
        let payload = AppPrefsData(autoLockSeconds: autoLockSeconds, privacyScreenEnabled: privacyScreenEnabled, noTraceMode: noTraceMode, onboardingDone: onboardingDone, languageCode: languageCode)
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
