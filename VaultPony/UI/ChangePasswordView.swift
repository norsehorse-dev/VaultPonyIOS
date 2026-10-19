import SwiftUI
import UniformTypeIdentifiers

/// Value pushed onto HomeView's NavigationPath — wraps the vault so the
/// destination knows which bookmark to open (PLAN.md section 6, P4).
struct ChangePasswordRoute: Hashable {
    let vault: SavedVault
}

/// Re-keys a container's header under a new password/PIM/keyfiles. Works
/// directly on the fd, no unlocked session involved — mirrors how the
/// core's own change_password is designed (doc §6).
struct ChangePasswordView: View {
    let vault: SavedVault
    @Environment(VaultStore.self) private var vaultStore

    @State private var oldPassphrase = ""
    @State private var oldPimText = "0"
    @State private var oldKeyfiles: [Data] = []
    @State private var oldKeyfileCount = 0
    @State private var showOldKeyfilePicker = false

    @State private var newPassphrase = ""
    @State private var confirmNewPassphrase = ""
    @State private var newPimText = "0"
    // Target KDF: nil keeps the current one, otherwise a core registry
    // name. Switching resets the new PIM so the new KDF's own default
    // applies, as VeraCrypt does.
    @State private var newKdf: String? = nil
    private let kdfOptions = Vault.hashOptions()
    @State private var newKeyfiles: [Data] = []
    @State private var newKeyfileCount = 0
    @State private var showNewKeyfilePicker = false

    @State private var isChanging = false
    @State private var errorMessage: String?
    @State private var succeeded = false

    var body: some View {
        Form {
            Section("Current Password") {
                RevealableSecureField(title: "Current password", text: $oldPassphrase)
                TextField("Current PIM (0 = default)", text: $oldPimText)
                    .keyboardType(.numberPad)
                keyfileRow(label: "Current keyfiles", count: oldKeyfileCount) { showOldKeyfilePicker = true }
            }

            Section {
                RevealableSecureField(title: "New password", text: $newPassphrase)
                RevealableSecureField(title: "Confirm new password", text: $confirmNewPassphrase)
                TextField("New PIM (0 = default)", text: $newPimText)
                    .keyboardType(.numberPad)
                keyfileRow(label: "New keyfiles", count: newKeyfileCount) { showNewKeyfilePicker = true }
            } header: {
                Text("New Password")
            } footer: {
                Text("The data inside the vault is untouched — only the password that unlocks it changes.")
            }

            Section {
                Picker("Key derivation", selection: $newKdf) {
                    Text("Keep current").tag(String?.none)
                    ForEach(kdfOptions, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .onChange(of: newKdf) { _, _ in newPimText = "0" }
            } footer: {
                if newKdf != nil {
                    Text("Only the header is re-encrypted with the new KDF. Leave the new PIM at 0 to use its default.")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            if succeeded {
                Section {
                    Text("Password changed.").foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Change Password")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isChanging {
                    ProgressView()
                } else {
                    Button("Change") {
                        Task { await changePassword() }
                    }
                    .disabled(!canChange)
                }
            }
        }
        .fileImporter(isPresented: $showOldKeyfilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            oldKeyfiles = Self.readKeyfiles(result)
            oldKeyfileCount = oldKeyfiles.count
        }
        .fileImporter(isPresented: $showNewKeyfilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            newKeyfiles = Self.readKeyfiles(result)
            newKeyfileCount = newKeyfiles.count
        }
    }

    private var canChange: Bool {
        !oldPassphrase.isEmpty && !newPassphrase.isEmpty && newPassphrase == confirmNewPassphrase
    }

    private func changePassword() async {
        errorMessage = nil
        succeeded = false
        isChanging = true
        defer { isChanging = false }

        let oldPim = UInt32(oldPimText) ?? 0
        let newPim = UInt32(newPimText) ?? 0

        do {
            let (fd, refreshedBookmark) = try FdOpener.openForUnlock(bookmark: vault.bookmarkData, writable: true)
            if let refreshedBookmark {
                vaultStore.updateBookmark(vault.id, data: refreshedBookmark)
            }
            try await Vault.changeContainerPassword(
                fd: fd,
                oldPassphrase: oldPassphrase,
                oldPim: oldPim,
                oldKeyfiles: oldKeyfiles,
                newPassphrase: newPassphrase,
                newPim: newPim,
                newKeyfiles: newKeyfiles,
                newPrf: newKdf
            )
            succeeded = true
            oldPassphrase = ""
            newPassphrase = ""
            confirmNewPassphrase = ""
            oldKeyfiles = []
            newKeyfiles = []
            oldKeyfileCount = 0
            newKeyfileCount = 0
        } catch let error as VaultError {
            errorMessage = error.message
        } catch let error as FdOpenError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func keyfileRow(label: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(LocalizedStringKey(label))
                Spacer()
                Text(count == 0 ? "None" : "\(count) selected")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func readKeyfiles(_ result: Result<[URL], Error>) -> [Data] {
        guard let urls = try? result.get() else { return [] }
        return urls.compactMap { url -> Data? in
            guard url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            return try? Data(contentsOf: url)
        }
    }
}
