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
    /// Default "Immediately" (2.0.0). A value already saved is kept.
    private(set) var autoLockSeconds: TimeInterval = 0

    /// Auto-lock choices in seconds (2.0.0): Immediately, 30 s, 1, 5 and
    /// 15 min, 1 h. There is no "Never"; any value outside the list reads
    /// as 1 hour.
    static let autoLockChoices: [TimeInterval] = [0, 30, 60, 300, 900, 3600]

    static func normalizedAutoLock(_ seconds: TimeInterval) -> TimeInterval {
        autoLockChoices.contains(seconds) ? seconds : 3600
    }
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
        #if DEBUG
        // fastlane's `snapshot` (and any other UI-test run) reuses the same
        // simulator app install across every device/language combination
        // (reinstall_app/erase_simulator are both off in the Snapfile, since
        // wiping the whole simulator for every combo is slow). Without this,
        // onboardingDone from the FIRST run would stay persisted forever,
        // so every later combination -- and every later manual test run on
        // that simulator -- would skip straight to Home and never show
        // onboarding again. SnapshotTests passes `-resetOnboarding` to force
        // a clean slate on every launch it drives.
        if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") {
            try? FileManager.default.removeItem(at: fileURL)
        }
        #endif
        load()
        LanguageOverride.update(languageCode)
    }

    func setAutoLockSeconds(_ seconds: TimeInterval) {
        autoLockSeconds = Self.normalizedAutoLock(seconds)
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
        autoLockSeconds = Self.normalizedAutoLock(decoded.autoLockSeconds)
        privacyScreenEnabled = decoded.privacyScreenEnabled
        noTraceMode = decoded.noTraceMode
        onboardingDone = decoded.onboardingDone
        languageCode = decoded.languageCode
        if autoLockSeconds != decoded.autoLockSeconds {
            save()
        }
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
