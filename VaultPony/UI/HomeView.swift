import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(VaultStore.self) private var vaultStore
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(AppPrefs.self) private var appPrefs
    @Environment(ShareInbox.self) private var shareInbox
    @State private var showImporter = false
    @State private var importError: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if vaultStore.vaults.isEmpty {
                    ContentUnavailableView(
                        "No Vaults Yet",
                        systemImage: "lock.shield",
                        description: Text("Open a VeraCrypt container to get started.")
                    )
                } else {
                    ForEach(vaultStore.vaults) { vault in
                        Button {
                            path.append(vault)
                        } label: {
                            VaultRow(vault: vault, title: vaultStore.label(for: vault))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                path.append(ChangePasswordRoute(vault: vault))
                            } label: {
                                Label("Change Password", systemImage: "key")
                            }
                            Button {
                                path.append(RecoveryRoute(vault: vault))
                            } label: {
                                Label("Recovery", systemImage: "wrench.and.screwdriver")
                            }
                        }
                    }
                    .onDelete(perform: removeVaults)
                }
            }
            .navigationTitle("VaultPony")
            // A lock (auto-lock included) leaves the vault's screens, so
            // file names don't stay on screen after the key is gone. Only
            // a real lock bumps this, so an unlock screen keeps what was
            // typed across an app switch.
            .onChange(of: sessionRegistry.lockGeneration) { _, _ in
                path = NavigationPath()
                // "Open new vault" after a conversion locks the TrueCrypt
                // vault and opens the new one in the same moment.
                if sessionRegistry.showSessionOnHome, sessionRegistry.session != nil {
                    path.append(OpenSessionRoute())
                }
            }
            .onChange(of: sessionRegistry.showSessionOnHome) { _, show in
                guard show, sessionRegistry.session != nil else { return }
                var fresh = NavigationPath()
                fresh.append(OpenSessionRoute())
                path = fresh
            }
            // Back on the list: a vault opened while the list keeps nothing
            // goes unless it is unlocked (2.0.0 rc4, plan 5.4). A share
            // waiting for a vault to be unlocked asks again.
            .onChange(of: path.count) { _, count in
                guard count == 0 else { return }
                vaultStore.pruneTransient(keeping: sessionRegistry.vaultId)
                if sessionRegistry.session == nil, shareInbox.awaitingUnlock {
                    shareInbox.awaitingUnlock = false
                }
            }
            // The share sheet picked a vault to unlock.
            .onChange(of: shareInbox.vaultToUnlock) { _, vault in
                guard let vault else { return }
                shareInbox.vaultToUnlock = nil
                var fresh = NavigationPath()
                fresh.append(vault)
                path = fresh
            }
            .navigationDestination(for: SavedVault.self) { vault in
                UnlockView(vault: vault)
            }
            .navigationDestination(for: OpenSessionRoute.self) { _ in
                VaultSessionView()
            }
            // String.self / FileTarget.self routing moved into
            // VaultSessionView (P6): the unlocked session now owns its
            // own Browser/Viewer navigation so it can present them as a
            // NavigationSplitView on iPad instead of pushing onto this
            // top-level stack.
            .navigationDestination(for: CreateVaultRoute.self) { _ in
                CreateContainerView(path: $path)
            }
            .navigationDestination(for: CreatedVaultSummary.self) { summary in
                VaultCreatedView(summary: summary, path: $path)
            }
            .navigationDestination(for: ChangePasswordRoute.self) { route in
                ChangePasswordView(vault: route.vault)
            }
            .navigationDestination(for: RecoveryRoute.self) { route in
                RecoveryView(vault: route.vault)
            }
            .navigationDestination(for: SettingsRoute.self) { _ in
                SettingsView()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        path.append(SettingsRoute())
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Open Vault", systemImage: "doc.badge.plus")
                        }
                        Button {
                            path.append(CreateVaultRoute())
                        } label: {
                            Label("Create Vault", systemImage: "lock.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("Couldn't Open File", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let (fd, bookmark) = try FdOpener.openForImport(url: url, writable: false)
            close(fd)
            let vault = vaultStore.add(bookmarkData: bookmark, displayName: url.lastPathComponent, mode: appPrefs.effectiveVaultListMode)
            path.append(vault)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func removeVaults(at offsets: IndexSet) {
        for index in offsets {
            vaultStore.remove(vaultStore.vaults[index].id)
        }
    }
}

/// The browser of a vault that is already unlocked, pushed straight from
/// Home (2.0.0 rc5: the new vault after "Convert to VeraCrypt").
struct OpenSessionRoute: Hashable {}

private struct VaultRow: View {
    let vault: SavedVault
    /// The file name, or "Vault 1" and so on when names are hidden.
    let title: String

    var body: some View {
        HStack {
            Image(systemName: "lock.doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(title)
                    .foregroundStyle(.primary)
                if let lastOpened = vault.lastOpened {
                    Text(lastOpened, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never opened")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
