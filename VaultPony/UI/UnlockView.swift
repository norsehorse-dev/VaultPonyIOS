import SwiftUI
import UniformTypeIdentifiers

struct UnlockView: View {
    let vault: SavedVault

    @Environment(VaultStore.self) private var vaultStore
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(AppPrefs.self) private var appPrefs

    @State private var passphrase = ""
    @State private var pimText = "0"
    @State private var keyfiles: [Data] = []
    @State private var keyfileCount = 0
    @State private var showKeyfilePicker = false

    @State private var useOuterProtected = false
    @State private var hiddenPassphrase = ""

    @State private var enableBiometric = false
    private let isBiometricAvailable = BiometricUnlock.isAvailable()
    private var isBiometricEnrolled: Bool { BiometricUnlock.isEnrolled(vaultId: vault.id) }

    @State private var progress = UnlockProgress()
    @State private var isUnlocking = false
    @State private var errorMessage: String?
    @State private var unlockedFacts: VolumeFacts?

    var body: some View {
        Form {
            if isBiometricAvailable && isBiometricEnrolled {
                Section {
                    Button {
                        Task { await unlockWithBiometric() }
                    } label: {
                        Label("Unlock with Face ID", systemImage: "faceid")
                    }
                    .disabled(isUnlocking)
                }
            }

            Section {
                SecureField("Password", text: $passphrase)
                TextField("PIM (0 = default)", text: $pimText)
                    .keyboardType(.numberPad)
                if isBiometricAvailable && !isBiometricEnrolled {
                    Toggle("Enable Face ID for this vault", isOn: $enableBiometric)
                }
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
            VaultSessionView()
        }
    }

    private func unlockWithBiometric() async {
        errorMessage = nil
        do {
            passphrase = try await BiometricUnlock.retrieve(vaultId: vault.id, reason: String(localized: "Unlock \(vault.displayName)"))
        } catch {
            errorMessage = "Face ID unlock isn't available for this vault right now. Enter your password instead."
            return
        }
        await unlock(viaBiometric: true)
    }

    private func unlock(viaBiometric: Bool = false) async {
        errorMessage = nil
        isUnlocking = true
        defer { isUnlocking = false }

        let pim = UInt32(pimText) ?? 0

        do {
            var fd: Int32
            var copyModeInfo: CopyModeInfo? = nil

            // Always ask for a writable fd now (P2). Some storage
            // providers can't reliably grant one even though the bookmark
            // resolves fine — fall back to a local copy-in/copy-back
            // rather than force the user into a read-only unlock, unless
            // no-trace mode explicitly disables that fallback (P5).
            do {
                let (openedFd, refreshedBookmark) = try FdOpener.openForUnlock(bookmark: vault.bookmarkData, writable: true)
                if let refreshedBookmark {
                    vaultStore.updateBookmark(vault.id, data: refreshedBookmark)
                }
                fd = openedFd
            } catch FdOpenError.openFailed {
                guard !appPrefs.noTraceMode else {
                    throw FdOpenError.noTraceCopyInDisabled
                }
                let (copyFd, relativePath) = try FdOpener.openViaCopyIn(bookmark: vault.bookmarkData)
                fd = copyFd
                copyModeInfo = CopyModeInfo(relativePath: relativePath, bookmark: vault.bookmarkData, displayName: vault.displayName)
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
            sessionRegistry.adopt(session, vaultId: vault.id, facts: facts, copyModeInfo: copyModeInfo)
            vaultStore.touch(vault.id, filesystem: facts.filesystem)

            if enableBiometric, !isBiometricEnrolled {
                try? BiometricUnlock.enroll(vaultId: vault.id, passphrase: passphrase)
            }

            passphrase = ""
            hiddenPassphrase = ""
            keyfiles = []
            keyfileCount = 0

            unlockedFacts = facts
        } catch let error as VaultError {
            if viaBiometric, case .NotFoundOrWrongPassword = error {
                // The stored credential no longer matches — most likely
                // the password was changed since it was enrolled. Wipe it
                // rather than let Face ID keep offering a dead shortcut.
                BiometricUnlock.remove(vaultId: vault.id)
                errorMessage = "Face ID unlock used an outdated password. Enter the current password instead."
            } else {
                errorMessage = error.message
            }
        } catch let error as FdOpenError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
