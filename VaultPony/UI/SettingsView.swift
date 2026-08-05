import SwiftUI
import UIKit

/// Value pushed onto HomeView's NavigationPath — empty marker, same role
/// as CreateVaultRoute (PLAN.md section 6, P5).
struct SettingsRoute: Hashable {}

struct SettingsView: View {
    @Environment(AppPrefs.self) private var appPrefs
    @Environment(SessionRegistry.self) private var sessionRegistry

    private static let autoLockOptions: [(label: String, seconds: TimeInterval)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("1 hour", 3600),
        ("Never", .infinity),
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
                        Text(option.label).tag(option.seconds)
                    }
                }
            } footer: {
                Text("How long the vault stays unlocked with the app in the background.")
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

            Section {
                HStack {
                    Text("Language")
                    Spacer()
                    Text("System")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } footer: {
                Text("VaultPony follows the per-app language set in iOS Settings.")
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
            }
        }
        .navigationTitle("Settings")
    }
}
