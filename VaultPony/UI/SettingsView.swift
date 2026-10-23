import SwiftUI
import UIKit

/// Value pushed onto HomeView's NavigationPath — empty marker, same role
/// as CreateVaultRoute (PLAN.md section 6, P5).
struct SettingsRoute: Hashable {}

/// One of the pony family's other apps, cross-promoted here (parity port
/// of VaultPonyAndroid's SettingsScreen `PONY_APPS` list — same names,
/// subtitles, and URLs).
private struct PonyApp: Identifiable {
    let name: String
    let subtitle: String
    let url: String
    var id: String { name }
}

private let ponyApps: [PonyApp] = [
    PonyApp(name: "PGPony", subtitle: "OpenPGP encryption", url: "https://pgpony.app"),
    PonyApp(name: "PassPony", subtitle: "Password manager", url: "https://passpony.app"),
    PonyApp(name: "BurnPony", subtitle: "Burn-after-reading notes", url: "https://burnpony.app"),
    PonyApp(name: "CarrierPony", subtitle: "Async PGP messenger", url: "https://carrierpony.com"),
    PonyApp(name: "AgePony", subtitle: "age encryption", url: "https://agepony.com"),
    PonyApp(name: "RelayPony", subtitle: "Encrypted file transfer", url: "https://relaypony.app"),
    PonyApp(name: "QuorumPony", subtitle: "Key backup with secret sharing", url: "https://quorumpony.com"),
]

private struct SettingsLink: Identifiable {
    let label: String
    let url: String
    var id: String { label }
}

private let settingsLinks: [SettingsLink] = [
    SettingsLink(label: "Website", url: "https://vaultpony.app"),
    SettingsLink(label: "The Pony Family", url: "https://pony.norsehor.se"),
    SettingsLink(label: "Source code (VaultPonyIOS)", url: "https://github.com/norsehorse-dev/VaultPonyIOS"),
    SettingsLink(label: "Source code (VaultPonyCore)", url: "https://github.com/norsehorse-dev/VaultPonyCore"),
    SettingsLink(label: "Contact", url: "mailto:NorseHorse@norsehor.se"),
]

struct SettingsView: View {
    @Environment(AppPrefs.self) private var appPrefs
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(VaultStore.self) private var vaultStore

    /// "Don't keep" deletes every entry, so it asks first.
    @State private var confirmDontKeep = false

    // Same seconds as AppPrefs.autoLockChoices. No "Never" since 2.0.0.
    private static let autoLockOptions: [(label: String, seconds: TimeInterval)] = [
        ("Immediately", 0),
        ("After 30 seconds", 30),
        ("After 1 minute", 60),
        ("After 5 minutes", 300),
        ("After 15 minutes", 900),
        ("After 1 hour", 3600),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Auto-Lock", selection: Binding(
                    get: { appPrefs.autoLockSeconds },
                    set: { newValue in
                        appPrefs.setAutoLockSeconds(newValue)
                        sessionRegistry.autoLockSeconds = newValue
                    }
                )) {
                    ForEach(Self.autoLockOptions, id: \.seconds) { option in
                        Text(LocalizedStringKey(option.label)).tag(option.seconds)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How long vaults stay unlocked after you leave the app or turn off the screen.")
                    Text("A longer delay keeps the vault's key in memory while the app is in the background.")
                }
            }

            Section {
                Toggle("Privacy Screen", isOn: Binding(
                    get: { appPrefs.privacyScreenEnabled },
                    set: { appPrefs.setPrivacyScreenEnabled($0) }
                ))
            } footer: {
                Text("Hides vault content in the app switcher when VaultPony isn't active. iOS has no way to block screen recordings or photos of the screen — this covers the switcher thumbnail only.")
            }

            Section {
                Toggle("No-Trace Mode", isOn: Binding(
                    get: { appPrefs.noTraceMode },
                    set: { appPrefs.setNoTraceMode($0) }
                ))
            } footer: {
                Text("Never write decrypted content outside the vault. Disables the copy-in fallback for containers that can't be edited in place, and asks for confirmation before every export.")
            }

            // 2.0.0 rc4, plan 5.4. No-trace mode stays separate: while it is
            // on, newly opened vaults are kept in memory only, and saved
            // entries are left as they are.
            Section {
                Picker("Vault list", selection: Binding(
                    get: { appPrefs.vaultListMode },
                    set: { chooseVaultListMode($0) }
                )) {
                    Text("Show names").tag(VaultListMode.showNames)
                    Text("Hide names").tag(VaultListMode.hideNames)
                    Text("Don't keep").tag(VaultListMode.dontKeep)
                }
            } footer: {
                if appPrefs.vaultListMode == .hideNames {
                    Text("The list shows Vault 1, Vault 2 and so on. The saved link to each file still records where it is, because VaultPony needs it to open the file again.")
                }
            }

            Section {
                LanguageOptionRow(title: Text("System"), isSelected: appPrefs.languageCode == nil) {
                    appPrefs.setLanguageCode(nil)
                }
                ForEach(SupportedLanguage.all) { language in
                    LanguageOptionRow(title: Text(language.nativeName), isSelected: appPrefs.languageCode == language.code) {
                        appPrefs.setLanguageCode(language.code)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Changes apply immediately, without restarting VaultPony.")
            }

            Section {
                ForEach(ponyApps) { app in
                    Button {
                        openURL(app.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .foregroundStyle(.primary)
                            Text(LocalizedStringKey(app.subtitle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("More Pony Apps")
            }

            Section {
                ForEach(settingsLinks) { link in
                    Button {
                        openURL(link.url)
                    } label: {
                        Text(LocalizedStringKey(link.label))
                    }
                }
            } header: {
                Text("Links")
            }

            Section {
                Button {
                    appPrefs.requestReplayOnboarding()
                } label: {
                    Text("Show the Intro Again")
                }
            } header: {
                Text("Help")
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Core Version")
                    Spacer()
                    Text(Vault.coreVersionText())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            } footer: {
                Text("VaultPony is part of the pony family of privacy tools: encryption you can inspect instead of taking a developer's word for it.")
            }
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("settingsScreen")
        .alert("Remove all vaults from the list?", isPresented: $confirmDontKeep) {
            Button("Remove", role: .destructive) {
                vaultStore.removeAll()
                appPrefs.setVaultListMode(.dontKeep)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The vault files themselves are not touched. Saved Face ID or fingerprint unlocks for them are removed too.")
        }
    }

    private func chooseVaultListMode(_ mode: VaultListMode) {
        guard mode != appPrefs.vaultListMode else { return }
        switch mode {
        case .showNames:
            appPrefs.setVaultListMode(.showNames)
        case .hideNames:
            // Names already stored go now; new entries store none.
            vaultStore.wipeDisplayNames()
            appPrefs.setVaultListMode(.hideNames)
        case .dontKeep:
            confirmDontKeep = true
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        UIApplication.shared.open(url)
    }
}
