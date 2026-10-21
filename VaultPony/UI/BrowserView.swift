import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Identifies the file currently selected for preview. Bound between
/// BrowserView and VaultSessionView's detail column (P6); no longer a
/// NavigationPath push target.
struct FileTarget: Hashable {
    let path: String
    let name: String
}

/// What the screen's one file picker is open for. SwiftUI honors only one
/// `.fileImporter` per view, so the mode switches its content types.
private enum PickerMode {
    case importFiles
    case importFolder
    case exportDestination
}

/// A bulk import between its walk and the start of the copy, while the
/// pre-flight questions are open.
private struct PendingImport {
    let items: [TransferItem]
    let sources: [URL]
    let scopedURLs: [URL]
    let destination: String
    let maxFileBytes: UInt64?
    let clusterBytes: UInt64
    let freeBytes: UInt64?
    let firstPlan: TransferPlan
}

private struct SpaceShortfall {
    let needed: UInt64
    let free: UInt64
}

/// A vault folder to export, waiting for confirmation or a destination.
private struct FolderExport {
    let path: String
    let name: String
}

struct BrowserView: View {
    let path: String
    @Binding var selectedFile: FileTarget?

    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(AppPrefs.self) private var appPrefs
    @Environment(VaultStore.self) private var vaultStore
    @State private var entries: [DirEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""

    @State private var showPicker = false
    @State private var pickerMode: PickerMode = .importFiles
    @State private var isBusy = false

    @State private var entryToRename: DirEntry?
    @State private var renameText = ""

    @State private var pendingExportEntry: DirEntry?
    @State private var exportURL: URL?
    @State private var showExportSheet = false

    // Bulk import pre-flight (2.0.0).
    @State private var pendingImport: PendingImport?
    @State private var showCollisionPrompt = false
    @State private var tooLargeOnlyCount: Int?
    @State private var spaceShortfall: SpaceShortfall?

    // Folder export (2.0.0).
    @State private var folderExportToConfirm: FolderExport?
    @State private var folderExportAwaitingDestination: FolderExport?

    @State private var showVolumeInfo = false

    private var canWrite: Bool {
        sessionRegistry.facts?.writable == true
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn't Load Folder",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if entries.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else {
                List(entries, id: \.name) { entry in
                    row(for: entry)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if sessionRegistry.isCopyMode {
                    copyModeBanner
                }
                statusBar
            }
        }
        .navigationTitle(titleForPath)
        .toolbar {
            // Locks now, whatever the auto-lock delay, through the same path
            // as the Home Screen quick action: a running copy stops, a
            // copy-mode vault stages its "Save Changes?" write-back, and
            // HomeView returns to Home on the lockGeneration bump.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sessionRegistry.lockAll()
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                .accessibilityIdentifier("lockButton")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        newFolderName = ""
                        showNewFolderPrompt = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(!canWrite)

                    Button {
                        openPicker(.importFiles)
                    } label: {
                        Label("Import Files", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!canWrite)

                    Button {
                        openPicker(.importFolder)
                    } label: {
                        Label("Import Folder", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(!canWrite)

                    Divider()

                    Button {
                        requestFolderExport(FolderExport(path: path, name: currentFolderExportName))
                    } label: {
                        Label("Export Folder", systemImage: "square.and.arrow.up.on.square")
                    }

                    Button {
                        showVolumeInfo = true
                    } label: {
                        Label("Volume Info", systemImage: "info.circle")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .task {
            await load()
            if sessionRegistry.space == nil {
                await sessionRegistry.refreshSpace()
            }
        }
        .refreshable { await load() }
        .onChange(of: sessionRegistry.contentGeneration) { _, _ in
            Task { await load() }
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createFolder() } }
        }
        .alert("Rename", isPresented: Binding(
            get: { entryToRename != nil },
            set: { if !$0 { entryToRename = nil } }
        ), presenting: entryToRename) { entry in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { entryToRename = nil }
            Button("Rename") { Task { await performRename(entry) } }
        }
        .alert("Export Decrypted File?", isPresented: Binding(
            get: { pendingExportEntry != nil },
            set: { if !$0 { pendingExportEntry = nil } }
        ), presenting: pendingExportEntry) { entry in
            Button("Export", role: .destructive) {
                Task { await export(entry) }
            }
            Button("Cancel", role: .cancel) { pendingExportEntry = nil }
        } message: { entry in
            Text("No-trace mode is on. Exporting \"\(entry.name)\" writes a decrypted copy outside the vault.")
        }
        .alert("Export Decrypted Folder?", isPresented: Binding(
            get: { folderExportToConfirm != nil },
            set: { if !$0 { folderExportToConfirm = nil } }
        ), presenting: folderExportToConfirm) { target in
            Button("Export", role: .destructive) {
                chooseExportDestination(for: target)
            }
            Button("Cancel", role: .cancel) { folderExportToConfirm = nil }
        } message: { target in
            Text("No-trace mode is on. Exporting \"\(target.name)\" writes a decrypted copy outside the vault.")
        }
        .alert("Some Files Already Exist", isPresented: $showCollisionPrompt) {
            Button("Keep Both") { Task { await finishImportPreflight(policy: .keepBoth) } }
                .keyboardShortcut(.defaultAction)
            Button("Skip") { Task { await finishImportPreflight(policy: .skip) } }
            Button("Replace", role: .destructive) { Task { await finishImportPreflight(policy: .replace) } }
            Button("Cancel", role: .cancel) { abandonImport() }
        } message: {
            if let count = pendingImport?.firstPlan.tooLargeCount, count > 0 {
                Text("\(count) files are larger than 4 GB, which FAT can't store. They will be skipped.")
            }
        }
        .alert(Text("\(tooLargeOnlyCount ?? 0) files are larger than 4 GB, which FAT can't store. They will be skipped."), isPresented: Binding(
            get: { tooLargeOnlyCount != nil },
            set: { if !$0 { tooLargeOnlyCount = nil } }
        )) {
            Button("Continue") { Task { await finishImportPreflight(policy: .keepBoth) } }
            Button("Cancel", role: .cancel) { abandonImport() }
        }
        .alert("Not Enough Space", isPresented: Binding(
            get: { spaceShortfall != nil },
            set: { if !$0 { spaceShortfall = nil } }
        ), presenting: spaceShortfall) { _ in
            Button("OK", role: .cancel) { spaceShortfall = nil }
        } message: { shortfall in
            Text("These files need \(ByteFormat.string(shortfall.needed)) but the vault has \(ByteFormat.string(shortfall.free)) free.")
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: pickerMode == .importFiles ? [.item] : [.folder],
            allowsMultipleSelection: pickerMode == .importFiles
        ) { result in
            let mode = pickerMode
            let exportTarget = folderExportAwaitingDestination
            folderExportAwaitingDestination = nil
            guard let urls = try? result.get(), !urls.isEmpty else { return }
            switch mode {
            case .importFiles, .importFolder:
                Task { await beginImport(urls) }
            case .exportDestination:
                if let exportTarget, let destination = urls.first {
                    Task { await beginFolderExport(exportTarget, to: destination) }
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            if let exportURL {
                ShareSheet(activityItems: [exportURL])
            }
        }
        .sheet(isPresented: $showVolumeInfo) {
            VolumeInfoView()
                .environment(sessionRegistry)
                .environment(\.locale, appPrefs.locale)
        }
        .onChange(of: showExportSheet) { _, isShowing in
            // The share sheet is our only signal the export is done with
            // — clean up the decrypted temp copy the moment it closes
            // rather than leaving it in tmp/ (P5 no-trace/file-protection
            // audit).
            guard !isShowing, let exportURL else { return }
            try? FileManager.default.removeItem(at: exportURL)
            self.exportURL = nil
        }
        .overlay {
            if isBusy {
                ProgressView()
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var copyModeBanner: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("Editing a local copy — changes are written back when you lock the vault.")
                .font(.caption)
            Spacer()
        }
        .padding(8)
        .background(.yellow.opacity(0.2))
    }

    /// Which volume is open (hidden, or outer with the hidden area
    /// protected; nothing for a plain outer unlock) and the free space.
    @ViewBuilder
    private var statusBar: some View {
        let facts = sessionRegistry.facts
        let space = sessionRegistry.space
        if facts?.hidden == true || facts?.outerProtected == true || space != nil {
            HStack(spacing: 8) {
                if facts?.hidden == true {
                    Label("Hidden volume", systemImage: "eye.slash")
                } else if facts?.outerProtected == true {
                    Label("Hidden area protected", systemImage: "lock.shield")
                }
                Spacer(minLength: 0)
                if let space {
                    Text("\(ByteFormat.string(space.freeBytes)) free of \(ByteFormat.string(space.totalBytes))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func row(for entry: DirEntry) -> some View {
        Group {
            if entry.isDir {
                NavigationLink(value: childPath(entry.name)) {
                    EntryRow(entry: entry)
                }
            } else {
                // P6 iPad split-view: selecting a file sets the shared
                // binding instead of pushing onto a NavigationPath, so
                // ViewerView can render in the detail column beside this
                // list rather than replacing it.
                Button {
                    selectedFile = FileTarget(path: childPath(entry.name), name: entry.name)
                } label: {
                    EntryRow(entry: entry)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(isSelected(entry) ? Color.accentColor.opacity(0.15) : Color.clear)
        .swipeActions(edge: .trailing) {
            if canWrite {
                Button(role: .destructive) {
                    Task { await delete(entry) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    entryToRename = entry
                    renameText = entry.name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.orange)
            }
            Button {
                if entry.isDir {
                    requestFolderExport(FolderExport(path: childPath(entry.name), name: entry.name))
                } else if appPrefs.noTraceMode {
                    pendingExportEntry = entry
                } else {
                    Task { await export(entry) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)
        }
    }

    private func isSelected(_ entry: DirEntry) -> Bool {
        !entry.isDir && selectedFile?.path == childPath(entry.name)
    }

    private var titleForPath: String {
        guard path != "/" else { return String(localized: "Vault", locale: LanguageOverride.locale) }
        return (path as NSString).lastPathComponent
    }

    /// Folder name an export of this screen's folder gets: the folder's own
    /// name, or the vault's name at the root.
    private var currentFolderExportName: String {
        guard path == "/" else { return (path as NSString).lastPathComponent }
        let vaultName = vaultStore.vaults.first { $0.id == sessionRegistry.vaultId }?.displayName ?? ""
        let base = (vaultName as NSString).deletingPathExtension
        return base.isEmpty ? String(localized: "Vault", locale: LanguageOverride.locale) : base
    }

    private func childPath(_ name: String) -> String {
        path == "/" ? "/\(name)" : "\(path)/\(name)"
    }

    private func load() async {
        guard let session = sessionRegistry.session else {
            errorMessage = String(localized: "Vault is locked.", locale: LanguageOverride.locale)
            isLoading = false
            return
        }
        isLoading = true
        do {
            let listed = try await Vault.list(session, path: path)
            entries = listed.sorted { lhs, rhs in
                if lhs.isDir != rhs.isDir {
                    return lhs.isDir
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            errorMessage = nil
        } catch let error as VaultError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - P2: write operations

    private func createFolder() async {
        guard let session = sessionRegistry.session else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await Vault.mkdir(session, path: childPath(name))
            try await Vault.flush(session)
            await load()
            await sessionRegistry.refreshSpace()
        } catch let error as VaultError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performRename(_ entry: DirEntry) async {
        guard let session = sessionRegistry.session else { return }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        entryToRename = nil
        guard !newName.isEmpty, newName != entry.name else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await Vault.rename(session, from: childPath(entry.name), to: childPath(newName))
            try await Vault.flush(session)
            await load()
        } catch let error as VaultError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ entry: DirEntry) async {
        guard let session = sessionRegistry.session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await Vault.remove(session, path: childPath(entry.name))
            try await Vault.flush(session)
            await load()
            await sessionRegistry.refreshSpace()
        } catch let error as VaultError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 2.0.0: bulk import

    private func openPicker(_ mode: PickerMode) {
        pickerMode = mode
        showPicker = true
    }

    /// Walks the picked files/folders, plans the copy, then asks the
    /// pre-flight questions (collisions, files too large for FAT) before
    /// anything is written.
    @MainActor
    private func beginImport(_ urls: [URL]) async {
        guard let session = sessionRegistry.session,
              sessionRegistry.activeTransfer == nil,
              pendingImport == nil else { return }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        isBusy = true
        let destination = path
        let maxFileBytes = sessionRegistry.facts?.maxFileBytes
        let space = try? await Vault.space(session)
        let walked = await Task.detached { ImportWalker.walk(urls) }.value
        let firstPlan = await Self.plan(session: session, items: walked.items, destination: destination, policy: .keepBoth, maxFileBytes: maxFileBytes, clusterBytes: space?.clusterBytes ?? 0)
        isBusy = false

        pendingImport = PendingImport(
            items: walked.items,
            sources: walked.sources,
            scopedURLs: scoped,
            destination: destination,
            maxFileBytes: maxFileBytes,
            clusterBytes: space?.clusterBytes ?? 0,
            freeBytes: space?.freeBytes,
            firstPlan: firstPlan
        )
        if firstPlan.collisionCount > 0 {
            // The FAT size note rides along in this alert's message.
            showCollisionPrompt = true
        } else if firstPlan.tooLargeCount > 0 {
            tooLargeOnlyCount = firstPlan.tooLargeCount
        } else {
            await finishImportPreflight(policy: .keepBoth)
        }
    }

    /// Re-plans with the user's collision choice, checks space, and starts
    /// the copy.
    @MainActor
    private func finishImportPreflight(policy: CollisionPolicy) async {
        guard let pending = pendingImport, let session = sessionRegistry.session else {
            abandonImport()
            return
        }
        let plan: TransferPlan
        if policy == .keepBoth {
            plan = pending.firstPlan
        } else {
            isBusy = true
            plan = await Self.plan(session: session, items: pending.items, destination: pending.destination, policy: policy, maxFileBytes: pending.maxFileBytes, clusterBytes: pending.clusterBytes)
            isBusy = false
        }
        if let free = pending.freeBytes, !plan.fits(freeBytes: free) {
            abandonImport()
            spaceShortfall = SpaceShortfall(needed: plan.bytesNeeded, free: free)
            return
        }
        pendingImport = nil
        let transfer = BulkTransfer(
            kind: .importing,
            steps: ImportWalker.steps(for: plan, sources: pending.sources),
            counts: BulkTransfer.Counts(
                skipped: plan.tooLargeCount + plan.skippedExistingCount,
                renamed: plan.renamedCount,
                keptBoth: plan.keptBothCount
            ),
            session: session,
            registry: sessionRegistry,
            scopedURLs: pending.scopedURLs
        )
        transfer.start()
    }

    private func abandonImport() {
        pendingImport?.scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        pendingImport = nil
    }

    private static func plan(session: VaultSession, items: [TransferItem], destination: String, policy: CollisionPolicy, maxFileBytes: UInt64?, clusterBytes: UInt64) async -> TransferPlan {
        await Task.detached {
            TransferPlanner.plan(items: items, into: destination, policy: policy, maxFileBytes: maxFileBytes, clusterBytes: clusterBytes) { folder in
                ((try? session.list(path: folder)) ?? []).map { ExistingEntry(name: $0.name, isDirectory: $0.isDir) }
            }
        }.value
    }

    // MARK: - 2.0.0: folder export

    private func requestFolderExport(_ target: FolderExport) {
        if appPrefs.noTraceMode {
            folderExportToConfirm = target
        } else {
            chooseExportDestination(for: target)
        }
    }

    private func chooseExportDestination(for target: FolderExport) {
        folderExportToConfirm = nil
        folderExportAwaitingDestination = target
        openPicker(.exportDestination)
    }

    /// Recreates the vault folder inside the picked destination folder. If
    /// a folder of that name is already there, the copy gets "name (1)".
    @MainActor
    private func beginFolderExport(_ target: FolderExport, to destination: URL) async {
        guard let session = sessionRegistry.session, sessionRegistry.activeTransfer == nil else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        isBusy = true
        do {
            let isTaken: (String) -> Bool = { name in
                FileManager.default.fileExists(atPath: destination.appending(path: name).path(percentEncoded: false))
            }
            // The vault's own name could be anything in a crafted container
            // (".." or a "/"), so it never reaches the local path unsanitized.
            let safeName = TransferNaming.sanitize(target.name)
            let folderName = isTaken(safeName) ? TransferNaming.keepBothName(for: safeName, isDirectory: true, isTaken: isTaken) : safeName
            let root = destination.appending(path: folderName, directoryHint: .isDirectory)
            let steps = try await ExportWalker.steps(session: session, vaultFolder: target.path, localFolder: root)
            isBusy = false
            let transfer = BulkTransfer(
                kind: .exporting,
                steps: steps,
                counts: BulkTransfer.Counts(),
                session: session,
                registry: sessionRegistry,
                scopedURLs: scoped ? [destination] : []
            )
            transfer.start()
        } catch {
            isBusy = false
            if scoped { destination.stopAccessingSecurityScopedResource() }
            errorMessage = (error as? VaultError)?.message ?? error.localizedDescription
        }
    }

    /// Chunked export: reads the vault file in bounded pieces into a
    /// temp file, then hands that off to the system share sheet. The
    /// temp file gets complete file protection immediately (P5
    /// file-protection audit) and is deleted as soon as the share sheet
    /// closes, regardless of no-trace mode.
    private func export(_ entry: DirEntry) async {
        guard let session = sessionRegistry.session else { return }
        isBusy = true
        defer { isBusy = false }

        let chunkSize: UInt32 = 4 << 20 // 4 MiB
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])

        do {
            guard let handle = FileHandle(forWritingAtPath: tempURL.path) else {
                throw FdOpenError.openFailed(errno: -1)
            }
            defer { try? handle.close() }

            let sourcePath = childPath(entry.name)
            var offset: UInt64 = 0
            while true {
                let data = try await Vault.readAt(session, path: sourcePath, offset: offset, len: chunkSize)
                if data.isEmpty { break }
                handle.write(data)
                offset += UInt64(data.count)
                if data.count < Int(chunkSize) { break }
            }
            exportURL = tempURL
            showExportSheet = true
        } catch let error as VaultError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EntryRow: View {
    let entry: DirEntry

    var body: some View {
        HStack {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDir ? .blue : .secondary)
            VStack(alignment: .leading) {
                Text(entry.name)
                if !entry.isDir {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Thin wrapper so UIActivityViewController (export's share sheet) can be
/// presented from SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
