import SwiftUI
import UniformTypeIdentifiers

/// Value pushed onto HomeView's NavigationPath to route to
/// CreateContainerView — an empty marker, same role as FileTarget plays
/// for BrowserView.
struct CreateVaultRoute: Hashable {}

/// What CreateContainerView hands to VaultCreatedView once creation
/// succeeds — the saved-vault record plus the choices made, for the
/// summary screen.
struct CreatedVaultSummary: Identifiable, Hashable {
    let vault: SavedVault
    let sizeBytes: UInt64
    let scheme: String
    let prf: String
    let filesystem: String
    let isHidden: Bool
    let hiddenSizeBytes: UInt64?

    var id: UUID { vault.id }
}

/// "Convert to VeraCrypt" (2.0.0 rc5, plan 6.2, D9): what the create form
/// starts on when it makes the new container for a TrueCrypt volume.
struct ConvertSetup {
    /// The new vault's name (the TrueCrypt vault's, without extension).
    let name: String
    /// Prefilled size in MiB: the TrueCrypt file's size, or the files plus
    /// 5% and 8 MiB if that is more.
    let suggestedMiB: UInt64
    /// Smallest size accepted: the files plus 8 MiB.
    let minimumBytes: UInt64
    /// A file is larger than FAT allows, so only exFAT is offered.
    let needsExFAT: Bool
    /// The TrueCrypt volume open is a hidden one.
    let fromHiddenVolume: Bool
}

/// The container the form made for a conversion, and what unlocks it. The
/// vault is already in the vault list.
struct ConvertTarget {
    let url: URL
    let bookmark: Data
    let vault: SavedVault
    let passphrase: String
    let pim: UInt32
    let keyfiles: [Data]
    let prf: String
}

private enum SizeUnit: String, CaseIterable, Identifiable {
    case mb = "MB"
    case gb = "GB"
    var id: String { rawValue }
    var bytesPerUnit: UInt64 {
        switch self {
        case .mb: return 1 << 20
        case .gb: return 1 << 30
        }
    }
}

/// Section 6 / P3: plain and hidden container creation. The destination
/// file is created empty via `.fileExporter` (a standard SwiftUI
/// FileDocument save panel) so the user picks where it lands exactly like
/// any other Files-app save; the core sizes it itself once we open it and
/// hand over the fd (doc §3).
struct CreateContainerView: View {
    @Environment(VaultStore.self) private var vaultStore
    @Environment(AppPrefs.self) private var appPrefs
    @Binding var path: NavigationPath

    /// Set for "Convert to VeraCrypt" (2.0.0 rc5): the same form, prefilled,
    /// without the hidden-volume option. Once the container is made it goes
    /// to `onConvert` instead of the summary screen.
    private let convert: ConvertSetup?
    private let onConvert: ((ConvertTarget) -> Void)?

    @State private var name = "MyVault"
    @State private var sizeText = "100"
    @State private var sizeUnit: SizeUnit = .mb

    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var pimText = "0"
    @State private var keyfiles: [Data] = []
    @State private var keyfileCount = 0
    @State private var showKeyfilePicker = false

    private let schemeOptions = Vault.encryptionSchemeOptions()
    private let prfOptions = Vault.hashOptions()
    private let filesystemOptions = Vault.filesystemOptions()
    @State private var scheme: String = Vault.encryptionSchemeOptions().first ?? "AES"
    @State private var prf: String = Vault.hashOptions().first ?? "SHA-512"
    @State private var filesystem: String = Vault.filesystemOptions().first ?? "FAT"

    @State private var isHiddenVolume = false
    @State private var hiddenPassphrase = ""
    @State private var confirmHiddenPassphrase = ""
    @State private var hiddenSizeText = "40"
    @State private var hiddenSizeUnit: SizeUnit = .mb

    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showExporter = false

    init(path: Binding<NavigationPath>, convert: ConvertSetup? = nil, onConvert: ((ConvertTarget) -> Void)? = nil) {
        _path = path
        self.convert = convert
        self.onConvert = onConvert
        if let convert {
            _name = State(initialValue: convert.name)
            _sizeText = State(initialValue: String(convert.suggestedMiB))
            if convert.needsExFAT {
                _filesystem = State(initialValue: Vault.filesystemOptions().first { $0.lowercased() == "exfat" } ?? "exFAT")
            }
        }
    }

    /// FAT can't hold a file over 4 GB, so a conversion that has one only
    /// offers exFAT.
    private var offeredFilesystems: [String] {
        guard convert?.needsExFAT == true else { return filesystemOptions }
        return filesystemOptions.filter { $0.lowercased() != "fat" }
    }

    /// The size typed, in bytes, or nil if it isn't a number that fits.
    private var typedSizeBytes: UInt64? {
        guard let value = UInt64(sizeText) else { return nil }
        let (bytes, overflow) = value.multipliedReportingOverflow(by: sizeUnit.bytesPerUnit)
        return overflow ? nil : bytes
    }

    /// For a conversion: the smallest size accepted, when the typed size is
    /// below it.
    private var conversionMinimumUnmet: UInt64? {
        guard let convert, let bytes = typedSizeBytes, bytes < convert.minimumBytes else { return nil }
        return convert.minimumBytes
    }

    var body: some View {
        Form {
            if let convert {
                Section {
                    Text("VaultPony makes a new VeraCrypt container and copies every file into it. The TrueCrypt container is not changed or deleted. Remove it yourself once you've checked the new one.")
                    if convert.fromHiddenVolume {
                        Text("This is a hidden TrueCrypt volume. It converts to an ordinary VeraCrypt container; the hidden-volume structure doesn't carry over.")
                    }
                }
            }

            Section("Name") {
                TextField("Vault name", text: $name)
            }

            Section {
                HStack {
                    TextField("Size", text: $sizeText)
                        .keyboardType(.numberPad)
                    Picker("Unit", selection: $sizeUnit) {
                        ForEach(SizeUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            } header: {
                Text("Size")
            } footer: {
                if let minimum = conversionMinimumUnmet {
                    Text("The new container needs to be at least \(ByteFormat.string(minimum)).")
                        .foregroundStyle(.red)
                }
            }

            Section("Password") {
                RevealableSecureField(title: "Password", text: $passphrase, contentType: .newPassword)
                RevealableSecureField(title: "Confirm password", text: $confirmPassphrase, contentType: .newPassword)
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
                        Text(keyfileCount == 0 ? LocalizedStringKey("None") : "\(keyfileCount) selected")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Scheme", selection: $scheme) {
                    // VeraCrypt's names ("AES-Twofish-Serpent"); the core
                    // still gets the registry name (2.0.0 rc4, D16).
                    ForEach(schemeOptions, id: \.self) { Text(verbatim: Vault.schemeLabel($0)).tag($0) }
                }
                Picker("Hash", selection: $prf) {
                    ForEach(prfOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("Filesystem", selection: $filesystem) {
                    ForEach(offeredFilesystems, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Encryption")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if prf == "Argon2id" {
                        Text("Argon2id is memory-hard: at the default PIM, opening this vault needs about 416 MB of free memory and takes a few seconds. Desktop VeraCrypt opens it from version 1.26.29.")
                    }
                    if convert?.needsExFAT == true {
                        Text("A file is larger than 4 GB, so the new container uses exFAT.")
                    }
                }
            }

            // No hidden volume when converting (plan 6.2).
            if convert == nil {
                Section {
                    Toggle("Hidden Volume", isOn: $isHiddenVolume)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("To open the hidden vault later, type the hidden password on its own in the normal password field.")
                        Text("Typing both passwords together opens the outer vault with the hidden area protected, so you can add decoy files safely.")
                    }
                }
            }

            if isHiddenVolume && convert == nil {
                Section("Hidden Volume Password") {
                    RevealableSecureField(title: "Hidden password", text: $hiddenPassphrase, contentType: .newPassword)
                    RevealableSecureField(title: "Confirm hidden password", text: $confirmHiddenPassphrase, contentType: .newPassword)
                }
                Section {
                    HStack {
                        TextField("Size", text: $hiddenSizeText)
                            .keyboardType(.numberPad)
                        Picker("Unit", selection: $hiddenSizeUnit) {
                            ForEach(SizeUnit.allCases) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                } header: {
                    Text("Hidden Volume Size")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Carved from the outer volume's space. It must leave enough room for the outer volume's own files.")
                        Text("Writing to the outer vault can overwrite the hidden one. To add files to the outer vault, unlock it with both passwords so the hidden area is protected.")
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
        .navigationTitle(convert == nil ? LocalizedStringKey("Create Vault") : LocalizedStringKey("Convert to VeraCrypt"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isCreating {
                    ProgressView()
                } else if convert != nil {
                    Button("Convert") {
                        showExporter = true
                    }
                    .disabled(!canCreate)
                } else {
                    Button("Create") {
                        showExporter = true
                    }
                    .disabled(!canCreate)
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
        .fileExporter(isPresented: $showExporter, document: EmptyVaultDocument(), contentType: .data, defaultFilename: "\(name).vc") { result in
            switch result {
            case .success(let url):
                Task { await create(at: url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let sizeValue = UInt64(sizeText), sizeValue > 0 else { return false }
        guard !passphrase.isEmpty, passphrase == confirmPassphrase else { return false }
        if let convert {
            guard let bytes = typedSizeBytes, bytes >= convert.minimumBytes else { return false }
            return offeredFilesystems.contains(filesystem)
        }
        if isHiddenVolume {
            guard !hiddenPassphrase.isEmpty, hiddenPassphrase == confirmHiddenPassphrase else { return false }
            guard let hiddenValue = UInt64(hiddenSizeText), hiddenValue > 0 else { return false }
            let outerBytes = sizeValue * sizeUnit.bytesPerUnit
            let hiddenBytes = hiddenValue * hiddenSizeUnit.bytesPerUnit
            guard hiddenBytes < outerBytes else { return false }
        }
        return true
    }

    private func create(at url: URL) async {
        errorMessage = nil
        isCreating = true
        defer { isCreating = false }

        guard let sizeValue = UInt64(sizeText) else { return }
        let sizeBytes = sizeValue * sizeUnit.bytesPerUnit
        let pim = UInt32(pimText) ?? 0

        do {
            let (fd, bookmark) = try FdOpener.openForImport(url: url, writable: true)

            if let onConvert, convert != nil {
                // The same creation as below; the conversion screen unlocks
                // it and copies into it.
                try await Vault.createNewContainer(
                    fd: fd,
                    size: sizeBytes,
                    passphrase: passphrase,
                    pim: pim,
                    keyfiles: keyfiles,
                    scheme: scheme,
                    prf: prf,
                    filesystem: filesystem
                )
                let vault = vaultStore.add(bookmarkData: bookmark, displayName: name, mode: appPrefs.effectiveVaultListMode)
                let target = ConvertTarget(url: url, bookmark: bookmark, vault: shownCopy(of: vault), passphrase: passphrase, pim: pim, keyfiles: keyfiles, prf: prf)
                clearSecrets()
                onConvert(target)
                return
            }

            if isHiddenVolume {
                guard let hiddenValue = UInt64(hiddenSizeText) else { return }
                let hiddenSizeBytes = hiddenValue * hiddenSizeUnit.bytesPerUnit
                try await Vault.createNewHiddenContainer(
                    fd: fd,
                    size: sizeBytes,
                    outerPassphrase: passphrase,
                    hiddenPassphrase: hiddenPassphrase,
                    pim: pim,
                    hiddenSize: hiddenSizeBytes,
                    scheme: scheme,
                    prf: prf,
                    filesystem: filesystem
                )
                let vault = vaultStore.add(bookmarkData: bookmark, displayName: name, mode: appPrefs.effectiveVaultListMode)
                let summary = CreatedVaultSummary(vault: shownCopy(of: vault), sizeBytes: sizeBytes, scheme: scheme, prf: prf, filesystem: filesystem, isHidden: true, hiddenSizeBytes: hiddenSizeBytes)
                clearSecrets()
                path.append(summary)
            } else {
                try await Vault.createNewContainer(
                    fd: fd,
                    size: sizeBytes,
                    passphrase: passphrase,
                    pim: pim,
                    keyfiles: keyfiles,
                    scheme: scheme,
                    prf: prf,
                    filesystem: filesystem
                )
                let vault = vaultStore.add(bookmarkData: bookmark, displayName: name, mode: appPrefs.effectiveVaultListMode)
                let summary = CreatedVaultSummary(vault: shownCopy(of: vault), sizeBytes: sizeBytes, scheme: scheme, prf: prf, filesystem: filesystem, isHidden: false, hiddenSizeBytes: nil)
                clearSecrets()
                path.append(summary)
            }
        } catch let error as VaultError {
            errorMessage = error.message
        } catch let error as FdOpenError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// With the vault list hiding names nothing is stored, but the summary
    /// right after creating still shows the name just typed.
    private func shownCopy(of vault: SavedVault) -> SavedVault {
        var shown = vault
        if shown.displayName.isEmpty {
            shown.displayName = name
        }
        return shown
    }

    private func clearSecrets() {
        passphrase = ""
        confirmPassphrase = ""
        hiddenPassphrase = ""
        confirmHiddenPassphrase = ""
        keyfiles = []
        keyfileCount = 0
    }
}

/// Minimal placeholder written to disk before create_container/
/// create_hidden_container size it themselves (core doc §3: "starts
/// empty; size it so create_volume's writes land at real offsets").
/// `.fileExporter` needs a FileDocument to drive the save panel; this one
/// carries no real content.
private struct EmptyVaultDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    init() {}
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
