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

    /// Files access for this unlock only, off by default (D20).
    @State private var showInFiles = false
    private let isBiometricAvailable = BiometricUnlock.isAvailable()
    private var isBiometricEnrolled: Bool { BiometricUnlock.isEnrolled(vaultId: vault.id) }

    @State private var progress = UnlockProgress()
    @State private var isUnlocking = false
    @State private var errorMessage: String?
    @State private var unlockedFacts: VolumeFacts?

    // The "Hash" menu (2.0.0 rc4, D21): `.auto` matches VeraCrypt; a single
    // hash skips every other derivation. "Skip Argon2id" still sets
    // `.pbkdf2Only`, which the menu then shows as PBKDF2.
    @State private var kdf: KdfFilter = .auto
    private let hashChoices = Vault.hashMenuChoices()
    /// Only a hash picked by hand is remembered, never what Auto found.
    @State private var hashPickedByHand = false
    @State private var appliedRememberedHash = false
    @State private var cancelHandle: UnlockCancel?
    @State private var memoryWarning: MemoryCheck?

    /// The name shown for this vault ("Vault 2" when names are hidden).
    private var vaultLabel: String { vaultStore.label(for: vault) }

    /// "Don't keep" or no-trace mode: no hash is remembered (D21).
    private var listKeepsNothing: Bool { appPrefs.effectiveVaultListMode == .dontKeep }

    /// "Don't keep" deletes the entry and its Face ID unlock at lock, so
    /// Face ID isn't offered. No-trace mode keeps its pre-rc4 behaviour.
    private var offersFaceID: Bool { appPrefs.vaultListMode != .dontKeep }

    /// Only "Auto" is translated; the others are hash names.
    private func hashTitle(_ choice: HashChoice) -> Text {
        choice.filter == .auto ? Text("Auto") : Text(verbatim: choice.label)
    }

    private var hashSelection: Binding<KdfFilter> {
        Binding(
            get: { kdf },
            set: { picked in
                kdf = picked
                hashPickedByHand = true
                if picked == .auto {
                    // Picking Auto forgets a remembered hash.
                    vaultStore.setRememberedHash(vault.id, hash: nil)
                }
            }
        )
    }

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
                if isBiometricAvailable && !isBiometricEnrolled && offersFaceID {
                    Toggle("Enable Face ID for this vault", isOn: $enableBiometric)
                }
            }

            Section {
                Picker("Hash", selection: hashSelection) {
                    ForEach(hashChoices, id: \.label) { choice in
                        hashTitle(choice).tag(choice.filter)
                    }
                    if kdf == .pbkdf2Only {
                        Text("PBKDF2").tag(KdfFilter.pbkdf2Only)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Auto tries every hash, like VeraCrypt. If you know which hash your vault uses, picking it makes unlocking faster.")
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

            if !appPrefs.noTraceMode {
                Section {
                    Toggle("Show in Files", isOn: $showInFiles)
                        .accessibilityIdentifier("showInFilesToggle")
                } footer: {
                    Text("Other apps can open and save files in this vault from the Files app while it stays unlocked. Files you open there are decrypted into VaultPony's storage on this device until you lock. With auto-lock set to Immediately, the vault stays unlocked until 2 minutes after you last use it in Files, and never more than 1 hour after you leave VaultPony.")
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
        .navigationTitle(vaultLabel)
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
        .onAppear {
            // The menu starts on a hash picked by hand last time.
            guard !appliedRememberedHash else { return }
            appliedRememberedHash = true
            if let remembered = vaultStore.rememberedHash(for: vault.id),
               let filter = Vault.kdfFilter(forHash: remembered) {
                kdf = filter
            }
        }
    }

    private func unlockWithBiometric() async {
        errorMessage = nil
        let credential: BiometricUnlock.StoredCredential
        do {
            credential = try await BiometricUnlock.retrieve(vaultId: vault.id, reason: String(localized: "Unlock \(vaultLabel)"))
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
        if Vault.mayUseArgon2(kdf) {
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
        // The app's own copy of the container fd for Files access, taken
        // before the core takes ownership of `fd`.
        var filesFd: Int32?
        defer {
            if let filesFd { close(filesFd) }
        }

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
                copyModeInfo = CopyModeInfo(relativePath: relativePath, bookmark: vault.bookmarkData, displayName: vaultLabel)
            }

            if showInFiles, !appPrefs.noTraceMode {
                let copy = dup(fd)
                filesFd = copy >= 0 ? copy : nil
            }
            // Only a session meant for Files keeps the extra copy of its
            // keys that the handoff needs (core THREAT_MODEL.md).
            // A local copy can't be shown in Files (D20); SessionRegistry
            // says so after the unlock.
            enableFilesHandoff(on: filesFd != nil && copyModeInfo == nil)

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
            let handedFilesFd = filesFd
            filesFd = nil
            sessionRegistry.adopt(session, vaultId: vault.id, facts: facts, copyModeInfo: copyModeInfo, filesFd: handedFilesFd)
            vaultStore.touch(vault.id, filesystem: facts.filesystem)

            // A hash picked by hand is remembered for this vault, unless
            // the list keeps nothing. Biometric unlocks keep their own KDF.
            if !viaBiometric, hashPickedByHand, !listKeepsNothing,
               let label = hashChoices.first(where: { $0.filter == kdf && $0.filter != .auto })?.label {
                vaultStore.setRememberedHash(vault.id, hash: label)
            }

            if enableBiometric, !isBiometricEnrolled, offersFaceID {
                // Remember which KDF family opened it, so a Face ID unlock
                // goes straight there next time.
                let found: KdfFilter = facts.prf == "Argon2id" ? .argon2idOnly : .pbkdf2Only
                try? BiometricUnlock.enroll(vaultId: vault.id, passphrase: passphrase, kdf: found)
            }

            passphrase = ""
            hiddenPassphrase = ""
            keyfiles = []
            keyfileCount = 0
            showInFiles = false

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
