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

    // Argon2id support (VeraCrypt 1.26.29+). `.auto` matches VeraCrypt;
    // narrowing skips the other KDF family's cost.
    @State private var kdf: KdfFilter = .auto
    @State private var cancelHandle: UnlockCancel?
    @State private var memoryWarning: MemoryCheck?

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
                RevealableSecureField(title: "Password", text: $passphrase, accessibilityIdentifier: "passwordField")
                TextField("PIM (0 = default)", text: $pimText)
                    .keyboardType(.numberPad)
                if isBiometricAvailable && !isBiometricEnrolled {
                    Toggle("Enable Face ID for this vault", isOn: $enableBiometric)
                }
            }

            Section {
                Picker("Key derivation", selection: $kdf) {
                    Text("Auto").tag(KdfFilter.auto)
                    Text("PBKDF2").tag(KdfFilter.pbkdf2Only)
                    Text("Argon2id").tag(KdfFilter.argon2idOnly)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Key derivation")
            } footer: {
                Text("Auto tries every KDF, like VeraCrypt. If you know which one your vault uses, picking it makes unlocking faster.")
            }

            Section {
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
            }

            Section {
                Toggle("Open the outer volume and protect a hidden one", isOn: $useOuterProtected)
                if useOuterProtected {
                    RevealableSecureField(title: "Hidden volume password", text: $hiddenPassphrase)
                }
            } footer: {
                // The first note shows on every unlock screen, hidden
                // volume or not, so the screen gives nothing away.
                VStack(alignment: .leading, spacing: 6) {
                    Text("A hidden volume opens when you type its password in the password field.")
                    if useOuterProtected {
                        Text("Unlocks the outer volume read-write while refusing any write that would land in the hidden region.")
                    }
                }
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

            if let warning = memoryWarning {
                Section {
                    Text("Argon2id at this PIM needs about \(warning.neededMib) MB of memory, and VaultPony can use about \(warning.availableMib) MB right now. Unlocking may fail.")
                        .foregroundStyle(.red)
                    Button("Try anyway") {
                        memoryWarning = nil
                        Task { await unlock(kdf: kdf) }
                    }
                    Button("Skip Argon2id") {
                        memoryWarning = nil
                        kdf = .pbkdf2Only
                        Task { await unlock(kdf: .pbkdf2Only) }
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
        // Leaving mid-unlock would abandon a search whose session could
        // still open behind the user; Cancel below stops it instead.
        .navigationBarBackButtonHidden(isUnlocking)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isUnlocking {
                    Button("Cancel") {
                        cancelHandle?.cancel()
                    }
                    .disabled(cancelHandle == nil)
                } else {
                    Button("Unlock") {
                        startUnlock()
                    }
                    .disabled(passphrase.isEmpty)
                    .accessibilityIdentifier("unlockButton")
                }
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
        let credential: BiometricUnlock.StoredCredential
        do {
            credential = try await BiometricUnlock.retrieve(vaultId: vault.id, reason: String(localized: "Unlock \(vault.displayName)"))
        } catch {
            errorMessage = String(localized: "Face ID unlock isn't available for this vault right now. Enter your password instead.", locale: LanguageOverride.locale)
            return
        }
        passphrase = credential.passphrase
        await unlock(viaBiometric: true, kdf: credential.kdf)
    }

    /// The Unlock button: check memory first when Argon2id may run, so a
    /// phone that can't spare it gets a choice instead of being killed.
    private func startUnlock() {
        errorMessage = nil
        memoryWarning = nil
        if kdf != .pbkdf2Only {
            let check = Vault.argon2MemoryCheck(pim: UInt32(pimText) ?? 0)
            if !check.enough {
                memoryWarning = check
                return
            }
        }
        Task { await unlock(kdf: kdf) }
    }

    private func unlock(viaBiometric: Bool = false, kdf: KdfFilter) async {
        errorMessage = nil
        isUnlocking = true
        let handle = UnlockCancel()
        cancelHandle = handle
        defer {
            isUnlocking = false
            cancelHandle = nil
        }

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
                    kdf: kdf,
                    cancel: handle,
                    progress: progress
                )
            } else {
                session = try await Vault.unlock(
                    fd: fd,
                    passphrase: passphrase,
                    pim: pim,
                    keyfiles: keyfiles,
                    kdf: kdf,
                    cancel: handle,
                    progress: progress
                )
            }

            let facts = try await Vault.facts(session)
            sessionRegistry.adopt(session, vaultId: vault.id, facts: facts, copyModeInfo: copyModeInfo)
            vaultStore.touch(vault.id, filesystem: facts.filesystem)

            if enableBiometric, !isBiometricEnrolled {
                // Remember which KDF family opened it, so a Face ID unlock
                // goes straight there next time.
                let found: KdfFilter = facts.prf == "Argon2id" ? .argon2idOnly : .pbkdf2Only
                try? BiometricUnlock.enroll(vaultId: vault.id, passphrase: passphrase, kdf: found)
            }

            passphrase = ""
            hiddenPassphrase = ""
            keyfiles = []
            keyfileCount = 0

            unlockedFacts = facts
        } catch VaultError.Cancelled {
            // The user's own action; nothing to report.
            errorMessage = nil
        } catch let error as VaultError {
            if viaBiometric, case .NotFoundOrWrongPassword = error {
                // The stored credential no longer matches — most likely
                // the password was changed since it was enrolled. Wipe it
                // rather than let Face ID keep offering a dead shortcut.
                BiometricUnlock.remove(vaultId: vault.id)
                errorMessage = String(localized: "Face ID unlock used an outdated password. Enter the current password instead.", locale: LanguageOverride.locale)
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
