import SwiftUI
import UniformTypeIdentifiers

struct UnlockView: View {
    let vault: SavedVault

    @Environment(VaultStore.self) private var vaultStore
    @Environment(SessionRegistry.self) private var sessionRegistry

    @State private var passphrase = ""
    @State private var pimText = "0"
    @State private var keyfiles: [Data] = []
    @State private var keyfileCount = 0
    @State private var showKeyfilePicker = false

    @State private var useOuterProtected = false
    @State private var hiddenPassphrase = ""

    @State private var progress = UnlockProgress()
    @State private var isUnlocking = false
    @State private var errorMessage: String?
    @State private var unlockedFacts: VolumeFacts?

    var body: some View {
        Form {
            Section {
                SecureField("Password", text: $passphrase)
                TextField("PIM (0 = default)", text: $pimText)
                    .keyboardType(.numberPad)
            }

            Section {
                Button {
                    showKeyfilePicker = true
                } label: {
                    HStack {
                        Text("Keyfiles")
                        Spacer()
                        Text(keyfileCount == 0 ? "None" : "\(keyfileCount) selected")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Outer volume, protect hidden", isOn: $useOuterProtected)
                if useOuterProtected {
                    SecureField("Hidden volume password", text: $hiddenPassphrase)
                }
            } footer: {
                Text("Unlocks the outer volume read-write while refusing any write that would land in the hidden region.")
            }

            if isUnlocking {
                Section {
                    HStack {
                        ProgressView(value: progress.total == 0 ? nil : Double(progress.step), total: Double(max(progress.total, 1)))
                        Text(progress.prf)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(vault.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Unlock") {
                    Task { await unlock() }
                }
                .disabled(passphrase.isEmpty || isUnlocking)
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
        .navigationDestination(item: $unlockedFacts) { _ in
            BrowserView(path: "/")
        }
    }

    private func unlock() async {
        errorMessage = nil
        isUnlocking = true
        defer { isUnlocking = false }

        let pim = UInt32(pimText) ?? 0

        do {
            let (fd, refreshedBookmark) = try FdOpener.openForUnlock(bookmark: vault.bookmarkData, writable: useOuterProtected)
            if let refreshedBookmark {
                vaultStore.updateBookmark(vault.id, data: refreshedBookmark)
            }

            let session: VaultSession
            if useOuterProtected {
                session = try await Vault.unlockOuterProtected(
                    fd: fd,
                    outerPassphrase: passphrase,
                    hiddenPassphrase: hiddenPassphrase,
                    pim: pim,
                    progress: progress
                )
            } else {
                session = try await Vault.unlock(
                    fd: fd,
                    passphrase: passphrase,
                    pim: pim,
                    keyfiles: keyfiles,
                    progress: progress
                )
            }

            let facts = try await Vault.facts(session)
            sessionRegistry.adopt(session, vaultId: vault.id, facts: facts)
            vaultStore.touch(vault.id, filesystem: facts.filesystem)

            passphrase = ""
            hiddenPassphrase = ""
            keyfiles = []
            keyfileCount = 0

            unlockedFacts = facts
        } catch let error as VaultError {
            errorMessage = error.message
        } catch let error as FdOpenError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
