import SwiftUI
import UniformTypeIdentifiers

/// Value pushed onto HomeView's NavigationPath — wraps the vault so the
/// destination knows which bookmark to open (PLAN.md section 6, P4).
struct RecoveryRoute: Hashable {
    let vault: SavedVault
}

/// Export the container's header backup, or restore the primary header
/// from a saved backup file or the container's own embedded copy (doc
/// §6). Both restore actions verify against the password/PIM/keyfiles
/// entered below before writing anything.
struct RecoveryView: View {
    let vault: SavedVault
    @Environment(VaultStore.self) private var vaultStore

    @State private var passphrase = ""
    @State private var pimText = "0"
    @State private var keyfiles: [Data] = []
    @State private var keyfileCount = 0
    @State private var showKeyfilePicker = false

    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    @State private var exportURL: URL?
    @State private var showExportSheet = false
    @State private var showBackupFilePicker = false

    var body: some View {
        Form {
            Section {
                Button("Export Header Backup…") {
                    Task { await exportBackup() }
                }
                .disabled(isBusy)
            } header: {
                Text("Export")
            } footer: {
                Text("Saves the container's 128 KiB header — encrypted, but keeps accepting the current password forever. Guard it like the container itself.")
            }

            Section {
                RevealableSecureField(title: "Password", text: $passphrase)
                TextField("PIM (0 = default)", text: $pimText)
                    .keyboardType(.numberPad)
                Button {
                    showKeyfilePicker = true
                } label: {
                    HStack {
                        Text("Keyfiles")
                        Spacer()
                        Text(keyfileCount == 0 ? LocalizedStringKey("None") : "\(keyfileCount) selected")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Verify With Password")
            } footer: {
                Text("Both restore actions below verify this password before writing anything — a wrong password leaves the container untouched.")
            }

            Section {
                Button("Restore From Backup File…") {
                    showBackupFilePicker = true
                }
                .disabled(passphrase.isEmpty || isBusy)

                Button("Restore From Embedded Backup") {
                    Task { await restoreFromEmbedded() }
                }
                .disabled(passphrase.isEmpty || isBusy)
            } header: {
                Text("Restore")
            } footer: {
                Text("Use the embedded backup when only the primary header is damaged. Use a saved backup file when both on-disk copies are gone.")
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
            if let successMessage {
                Section { Text(successMessage).foregroundStyle(.green) }
            }
        }
        .navigationTitle("Recovery")
        .overlay {
            if isBusy {
                ProgressView()
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .fileImporter(isPresented: $showKeyfilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let urls = try? result.get() else { return }
            keyfiles = urls.compactMap { url -> Data? in
                guard url.startAccessingSecurityScopedResource() else { return nil }
                defer { url.stopAccessingSecurityScopedResource() }
                return try? Data(contentsOf: url)
            }
            keyfileCount = keyfiles.count
        }
        .fileImporter(isPresented: $showBackupFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard let url = try? result.get().first else { return }
            Task { await restoreFromFile(url) }
        }
        .sheet(isPresented: $showExportSheet) {
            if let exportURL {
                ShareSheet(activityItems: [exportURL])
            }
        }
        .onChange(of: showExportSheet) { _, isShowing in
            guard !isShowing, let exportURL else { return }
            try? FileManager.default.removeItem(at: exportURL)
            self.exportURL = nil
        }
    }

    private var pim: UInt32 { UInt32(pimText) ?? 0 }

    private func exportBackup() async {
        errorMessage = nil
        successMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let (fd, _) = try FdOpener.openForUnlock(bookmark: vault.bookmarkData, writable: false)
            let backup = try await Vault.backupHeader(fd: fd)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(vaultStore.label(for: vault))-header-backup.bin")
            try backup.write(to: tempURL, options: [.atomic, .completeFileProtection])
            exportURL = tempURL
            showExportSheet = true
        } catch let error as VaultError {
            errorMessage = error.message
        } catch let error as FdOpenError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreFromFile(_ url: URL) async {
        errorMessage = nil
        successMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            guard url.startAccessingSecurityScopedResource() else { throw FdOpenError.accessDenied }
            let backupData = try Data(contentsOf: url)
            url.stopAccessingSecurityScopedResource()

            let (fd, refreshedBookmark) = try FdOpener.openForUnlock(bookmark: vault.bookmarkData, writable: true)
            if let refreshedBookmark {
                vaultStore.updateBookmark(vault.id, data: refreshedBookmark)
            }
            try await Vault.restoreHeaderFromBackupFile(fd: fd, backup: backupData, passphrase: passphrase, pim: pim, keyfiles: keyfiles)
            successMessage = String(localized: "Header restored from backup file. Try unlocking again.")
            clearSecrets()
        } catch let error as VaultError {
            errorMessage = error.message
        } catch let error as FdOpenError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreFromEmbedded() async {
        errorMessage = nil
        successMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let (fd, refreshedBookmark) = try FdOpener.openForUnlock(bookmark: vault.bookmarkData, writable: true)
            if let refreshedBookmark {
                vaultStore.updateBookmark(vault.id, data: refreshedBookmark)
            }
            try await Vault.restoreHeaderFromEmbeddedBackup(fd: fd, passphrase: passphrase, pim: pim, keyfiles: keyfiles)
            successMessage = String(localized: "Header restored from embedded backup. Try unlocking again.")
            clearSecrets()
        } catch let error as VaultError {
            errorMessage = error.message
        } catch let error as FdOpenError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Both restore actions succeed only after they've verified this
    /// password/keyfiles against the container — nothing left to retype,
    /// so drop them immediately rather than let them linger in memory
    /// for the rest of the screen's lifetime (P7 secrets-lifetime audit,
    /// matching the pattern already used in Unlock/CreateContainer/
    /// ChangePassword).
    private func clearSecrets() {
        passphrase = ""
        keyfiles = []
        keyfileCount = 0
    }
}
