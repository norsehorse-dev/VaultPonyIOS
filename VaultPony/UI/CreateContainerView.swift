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
    @Binding var path: NavigationPath

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

    var body: some View {
        Form {
            Section("Name") {
                TextField("Vault name", text: $name)
            }

            Section("Size") {
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
            }

            Section("Password") {
                RevealableSecureField(title: "Password", text: $passphrase)
                RevealableSecureField(title: "Confirm password", text: $confirmPassphrase)
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
                Picker("Scheme", selection: $scheme) {
                    ForEach(schemeOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("Hash", selection: $prf) {
                    ForEach(prfOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("Filesystem", selection: $filesystem) {
                    ForEach(filesystemOptions, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Encryption")
            } footer: {
                if prf == "Argon2id" {
                    Text("Argon2id is memory-hard: at the default PIM, opening this vault needs about 416 MB of free memory and takes a few seconds. Desktop VeraCrypt opens it from version 1.26.29.")
                }
            }

            Section {
                Toggle("Hidden Volume", isOn: $isHiddenVolume)
            } footer: {
                Text("Conceals a second volume inside this one. The outer password alone opens the decoy; the hidden password opens the real contents. The outer volume shows no trace of the hidden one.")
            }

            if isHiddenVolume {
                Section("Hidden Volume Password") {
                    RevealableSecureField(title: "Hidden password", text: $hiddenPassphrase)
                    RevealableSecureField(title: "Confirm hidden password", text: $confirmHiddenPassphrase)
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
                    Text("Carved from the outer volume's space — must leave enough room for the outer volume's own files.")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Create Vault")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isCreating {
                    ProgressView()
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
                let vault = vaultStore.add(bookmarkData: bookmark, displayName: name)
                let summary = CreatedVaultSummary(vault: vault, sizeBytes: sizeBytes, scheme: scheme, prf: prf, filesystem: filesystem, isHidden: true, hiddenSizeBytes: hiddenSizeBytes)
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
                let vault = vaultStore.add(bookmarkData: bookmark, displayName: name)
                let summary = CreatedVaultSummary(vault: vault, sizeBytes: sizeBytes, scheme: scheme, prf: prf, filesystem: filesystem, isHidden: false, hiddenSizeBytes: nil)
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
