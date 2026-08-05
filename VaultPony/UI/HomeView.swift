import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(VaultStore.self) private var vaultStore
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
                            VaultRow(vault: vault)
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
            .navigationDestination(for: SavedVault.self) { vault in
                UnlockView(vault: vault)
            }
            .navigationDestination(for: String.self) { subPath in
                BrowserView(path: subPath)
            }
            .navigationDestination(for: FileTarget.self) { target in
                ViewerView(path: target.path, name: target.name)
            }
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
            let vault = vaultStore.add(bookmarkData: bookmark, displayName: url.lastPathComponent)
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

private struct VaultRow: View {
    let vault: SavedVault

    var body: some View {
        HStack {
            Image(systemName: "lock.doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(vault.displayName)
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
