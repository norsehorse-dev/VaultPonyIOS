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
    /// Where the selected items go (2.0.0 rc4).
    case exportSelection
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

/// What the whole-vault search runs for; a change restarts it.
private struct SearchRequest: Equatable {
    let query: String
    let scope: SearchScope
    let generation: Int
}

/// One vault folder (2.0.0 rc4 adds the grid, sort, search and
/// multi-select, plan 5.3). Every core call goes through the `Vault`
/// wrappers; names Files or a copy in progress use for temporary files are
/// never shown, in the folder or in search results.
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

    // Search (2.0.0 rc4).
    @State private var searchText = ""
    @State private var searchScope: SearchScope = .thisFolder
    @State private var vaultHits: [SearchHit] = []
    @State private var isSearchingVault = false

    // Multi-select (2.0.0 rc4).
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var showDeleteSelectionPrompt = false
    @State private var showMovePicker = false
    @State private var selectionExportToConfirm: [DirEntry]?
    @State private var selectionAwaitingDestination: [DirEntry]?

    private var canWrite: Bool {
        sessionRegistry.facts?.writable == true
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isVaultSearch: Bool {
        searchScope == .wholeVault && !query.isEmpty
    }

    /// This folder, filtered by the search field ("This folder" scope) and
    /// sorted as chosen, folders first.
    private var displayedEntries: [DirEntry] {
        let filtered = query.isEmpty ? entries : entries.filter { BrowserSorting.matches($0.name, query) }
        return BrowserSorting.sorted(filtered, by: appPrefs.browserSort, ascending: appPrefs.browserAscending)
    }

    /// The selection, including items the search field hides right now.
    private var selectedEntries: [DirEntry] {
        entries.filter { selection.contains($0.name) }
    }

    var body: some View {
        withSheets
    }

    // MARK: - Layout

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn't Load Folder",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if isVaultSearch {
            vaultSearchResults
        } else if entries.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        } else if displayedEntries.isEmpty {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass")
        } else if appPrefs.browserLayout == .grid {
            gridView
        } else {
            List(displayedEntries, id: \.name) { entry in
                row(for: entry)
            }
        }
    }

    private var chrome: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if sessionRegistry.isCopyMode {
                        copyModeBanner
                    }
                    statusBar
                }
            }
            .navigationTitle(titleForPath)
            .navigationBarBackButtonHidden(isSelecting)
            .toolbar { toolbarContent }
            .searchable(text: $searchText, prompt: Text("Search"))
            .searchScopes($searchScope) {
                Text("This folder").tag(SearchScope.thisFolder)
                Text("Whole vault").tag(SearchScope.wholeVault)
            }
    }

    private var withTasks: some View {
        chrome
            .task {
                await load()
                if sessionRegistry.space == nil {
                    await sessionRegistry.refreshSpace()
                }
            }
            .task(id: SearchRequest(query: query, scope: searchScope, generation: sessionRegistry.contentGeneration)) {
                await runVaultSearch()
            }
            .refreshable { await load() }
            .onChange(of: sessionRegistry.contentGeneration) { _, _ in
                Task { await load() }
            }
    }

    private var withEntryAlerts: some View {
        withTasks
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
    }

    private var withImportAlerts: some View {
        withEntryAlerts
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
    }

    private var withSelectionAlerts: some View {
        withImportAlerts
            .alert(Text("Delete \(selection.count) items?"), isPresented: $showDeleteSelectionPrompt) {
                Button("Delete", role: .destructive) {
                    Task { await deleteSelection() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            .alert("Export Decrypted Files?", isPresented: Binding(
                get: { selectionExportToConfirm != nil },
                set: { if !$0 { selectionExportToConfirm = nil } }
            ), presenting: selectionExportToConfirm) { targets in
                Button("Export", role: .destructive) {
                    chooseSelectionDestination(targets)
                }
                Button("Cancel", role: .cancel) { selectionExportToConfirm = nil }
            } message: { _ in
                Text("No-trace mode is on. Exporting these items writes decrypted copies outside the vault.")
            }
    }

    private var withSheets: some View {
        withSelectionAlerts
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: pickerMode == .importFiles ? [.item] : [.folder],
                allowsMultipleSelection: pickerMode == .importFiles
            ) { result in
                let mode = pickerMode
                let exportTarget = folderExportAwaitingDestination
                folderExportAwaitingDestination = nil
                let selectionTargets = selectionAwaitingDestination
                selectionAwaitingDestination = nil
                guard let urls = try? result.get(), !urls.isEmpty else { return }
                switch mode {
                case .importFiles, .importFolder:
                    Task { await beginImport(urls) }
                case .exportDestination:
                    if let exportTarget, let destination = urls.first {
                        Task { await beginFolderExport(exportTarget, to: destination) }
                    }
                case .exportSelection:
                    if let selectionTargets, let destination = urls.first {
                        Task { await beginSelectionExport(selectionTargets, to: destination) }
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
            .sheet(isPresented: $showMovePicker) {
                VaultFolderPicker(
                    title: "Move to",
                    actionTitle: "Move here",
                    header: nil,
                    canEnter: { folder in !movingFolderPaths.contains(folder) },
                    canPick: { folder in canMove(into: folder) },
                    onPick: { destination in
                        showMovePicker = false
                        Task { await moveSelection(to: destination) }
                    },
                    onCancel: { showMovePicker = false }
                )
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Select all") {
                    selection = Set(displayedEntries.map(\.name))
                }
                .disabled(displayedEntries.allSatisfy { selection.contains($0.name) })
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") {
                    endSelection()
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if canWrite {
                    Button(role: .destructive) {
                        showDeleteSelectionPrompt = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)
                }
                Spacer()
                Text("\(selection.count) selected")
                    .font(.subheadline)
                Spacer()
                Button {
                    requestSelectionExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty || sessionRegistry.activeTransfer != nil)
                if canWrite {
                    Button {
                        showMovePicker = true
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                    .disabled(selection.isEmpty)
                }
            }
        } else {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") {
                    selection = []
                    isSelecting = true
                }
                .disabled(isLoading || entries.isEmpty || isVaultSearch)
            }
            ToolbarItem(placement: .topBarTrailing) {
                viewMenu
            }
            ToolbarItem(placement: .primaryAction) {
                addMenu
            }
        }
    }

    private var addMenu: some View {
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

    /// List or grid, and the order. Kept in app prefs for every vault.
    private var viewMenu: some View {
        Menu {
            Section {
                menuChoice("List", isOn: appPrefs.browserLayout == .list) { appPrefs.setBrowserLayout(.list) }
                menuChoice("Grid", isOn: appPrefs.browserLayout == .grid) { appPrefs.setBrowserLayout(.grid) }
            }
            Menu {
                Section {
                    menuChoice("Name", isOn: appPrefs.browserSort == .name) { appPrefs.setBrowserSort(.name) }
                    menuChoice("Size", isOn: appPrefs.browserSort == .size) { appPrefs.setBrowserSort(.size) }
                    menuChoice("Date modified", isOn: appPrefs.browserSort == .dateModified) { appPrefs.setBrowserSort(.dateModified) }
                }
                Section {
                    menuChoice("Ascending", isOn: appPrefs.browserAscending) { appPrefs.setBrowserAscending(true) }
                    menuChoice("Descending", isOn: !appPrefs.browserAscending) { appPrefs.setBrowserAscending(false) }
                }
            } label: {
                Label("Sort by", systemImage: "arrow.up.arrow.down")
            }
        } label: {
            Label("View", systemImage: "ellipsis.circle")
        }
    }

    private func menuChoice(_ title: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // MARK: - Rows

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
        if isSelecting {
            Button {
                toggle(entry)
            } label: {
                HStack(spacing: 12) {
                    SelectionMark(isOn: selection.contains(entry.name))
                    EntryRow(entry: entry)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(entry.name) ? .isSelected : [])
        } else {
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
                entryActions(entry)
            }
        }
    }

    /// Delete, Rename and Export for one item: swipe actions in the list,
    /// the context menu in the grid.
    @ViewBuilder
    private func entryActions(_ entry: DirEntry) -> some View {
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

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12)], spacing: 16) {
                ForEach(displayedEntries, id: \.name) { entry in
                    gridItem(for: entry)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func gridItem(for entry: DirEntry) -> some View {
        let cell = GridCell(
            entry: entry,
            path: childPath(entry.name),
            isSelecting: isSelecting,
            isChecked: selection.contains(entry.name),
            isHighlighted: isSelected(entry)
        )
        if isSelecting {
            Button {
                toggle(entry)
            } label: {
                cell
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(entry.name) ? .isSelected : [])
        } else if entry.isDir {
            NavigationLink(value: childPath(entry.name)) {
                cell
            }
            .buttonStyle(.plain)
            .contextMenu {
                entryActions(entry)
            }
        } else {
            Button {
                selectedFile = FileTarget(path: childPath(entry.name), name: entry.name)
            } label: {
                cell
            }
            .buttonStyle(.plain)
            .contextMenu {
                entryActions(entry)
            }
        }
    }

    /// "Whole vault" results: name, and the folder it is in.
    @ViewBuilder
    private var vaultSearchResults: some View {
        if vaultHits.isEmpty && !isSearchingVault {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass")
        } else {
            List {
                if isSearchingVault {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(vaultHits) { hit in
                    if hit.isDir {
                        NavigationLink(value: hit.path) {
                            SearchHitRow(hit: hit)
                        }
                    } else {
                        Button {
                            selectedFile = FileTarget(path: hit.path, name: hit.name)
                        } label: {
                            SearchHitRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
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
        let vaultName = vaultStore.vaults.first { $0.id == sessionRegistry.vaultId }.map { vaultStore.label(for: $0) } ?? ""
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
            var raw = try await Vault.list(session, path: path)
            // A Files save that finished writing but was cut off before its
            // swap: complete it, so the file doesn't look deleted.
            let done = raw.filter { !$0.isDir && FilesNaming.isDone($0.name) && FilesNaming.target(of: $0.name) != nil }
            if !done.isEmpty, sessionRegistry.facts?.writable == true {
                for entry in done {
                    if let target = FilesNaming.target(of: entry.name) {
                        try? await Vault.replace(session, src: childPath(entry.name), dst: childPath(target))
                    }
                }
                try? await Vault.flush(session)
                raw = try await Vault.list(session, path: path)
            }
            // Temp files of a copy or a Files save in progress stay hidden.
            // displayedEntries sorts and filters.
            entries = raw.filter { !FilesNaming.isHiddenFromListing($0.name) }
            if isSelecting {
                selection.formIntersection(entries.map(\.name))
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

    // MARK: - 2.0.0 rc4: search

    /// "Whole vault": walks the tree in the background. Restarted by
    /// `.task(id:)` whenever the query, the scope or the vault's content
    /// changes, and cancelled when this screen goes (a lock leaves it).
    @MainActor
    private func runVaultSearch() async {
        vaultHits = []
        guard isVaultSearch, let session = sessionRegistry.session else {
            isSearchingVault = false
            return
        }
        isSearchingVault = true
        // Typing settles first.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        await VaultSearch.walk(
            session: session,
            query: query,
            isOpen: { sessionRegistry.session === session },
            report: { hits in
                if !Task.isCancelled {
                    vaultHits = hits
                }
            }
        )
        if !Task.isCancelled {
            isSearchingVault = false
        }
    }

    // MARK: - 2.0.0 rc4: multi-select

    private func toggle(_ entry: DirEntry) {
        if selection.contains(entry.name) {
            selection.remove(entry.name)
        } else {
            selection.insert(entry.name)
        }
    }

    private func endSelection() {
        isSelecting = false
        selection = []
    }

    /// Selected folders, which Move must not enter or move into.
    private var movingFolderPaths: Set<String> {
        Set(selectedEntries.filter(\.isDir).map { childPath($0.name) })
    }

    private func canMove(into destination: String) -> Bool {
        guard destination != path else { return false }
        return !movingFolderPaths.contains { destination == $0 || destination.hasPrefix($0 + "/") }
    }

    /// Folders go with everything in them.
    @MainActor
    private func deleteSelection() async {
        guard let session = sessionRegistry.session else { return }
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            for entry in targets {
                try await VaultTreeOps.removeTree(session, path: childPath(entry.name), isDir: entry.isDir)
            }
            try await Vault.flush(session)
            endSelection()
            await load()
            await sessionRegistry.refreshSpace()
        } catch {
            await selectionFailed(error, session: session)
        }
    }

    @MainActor
    private func moveSelection(to destination: String) async {
        guard let session = sessionRegistry.session else { return }
        let targets = selectedEntries
        guard !targets.isEmpty, canMove(into: destination) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await VaultTreeOps.move(session, items: targets, from: path, to: destination)
            try await Vault.flush(session)
            endSelection()
            await load()
        } catch {
            await selectionFailed(error, session: session)
        }
    }

    /// A delete or move stopped partway (hidden volume protection, a full
    /// volume): keep what was done, say why, and pick up a switch to
    /// read-only.
    @MainActor
    private func selectionFailed(_ error: Error, session: VaultSession) async {
        try? await Vault.flush(session)
        endSelection()
        errorMessage = (error as? VaultError)?.message ?? error.localizedDescription
        await sessionRegistry.refreshFacts()
    }

    private func requestSelectionExport() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        if appPrefs.noTraceMode {
            selectionExportToConfirm = targets
        } else {
            chooseSelectionDestination(targets)
        }
    }

    private func chooseSelectionDestination(_ targets: [DirEntry]) {
        selectionExportToConfirm = nil
        selectionAwaitingDestination = targets
        openPicker(.exportSelection)
    }

    /// The selected files and folders, through the bulk export, into the
    /// picked folder. A name already there gets "name (1)".
    @MainActor
    private func beginSelectionExport(_ targets: [DirEntry], to destination: URL) async {
        guard let session = sessionRegistry.session, sessionRegistry.activeTransfer == nil else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        isBusy = true
        do {
            var used = Set<String>()
            let isTaken: (String) -> Bool = { name in
                used.contains(TransferNaming.fold(name))
                    || FileManager.default.fileExists(atPath: destination.appending(path: name).path(percentEncoded: false))
            }
            var steps: [TransferStep] = []
            for entry in targets {
                // Vault names never reach a local path unsanitized.
                let safeName = TransferNaming.sanitize(entry.name)
                let name = isTaken(safeName) ? TransferNaming.keepBothName(for: safeName, isDirectory: entry.isDir, isTaken: isTaken) : safeName
                used.insert(TransferNaming.fold(name))
                if entry.isDir {
                    let folder = destination.appending(path: name, directoryHint: .isDirectory)
                    steps += try await ExportWalker.steps(session: session, vaultFolder: childPath(entry.name), localFolder: folder)
                } else {
                    let file = destination.appending(path: name, directoryHint: .notDirectory)
                    steps.append(.exportFile(sourcePath: childPath(entry.name), dest: file, size: entry.size))
                }
            }
            isBusy = false
            endSelection()
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
        let firstPlan = await ImportWalker.plan(session: session, items: walked.items, destination: destination, policy: .keepBoth, maxFileBytes: maxFileBytes, clusterBytes: space?.clusterBytes ?? 0)
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
            plan = await ImportWalker.plan(session: session, items: pending.items, destination: pending.destination, policy: policy, maxFileBytes: pending.maxFileBytes, clusterBytes: pending.clusterBytes)
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

/// The SF Symbol for an item: folder, video, audio, image, or document.
enum EntryIcon {
    static func name(isDir: Bool, fileName: String) -> String {
        if isDir { return "folder.fill" }
        if let type = MediaPlayback.contentType(for: fileName) {
            return type.conforms(to: .audio) ? "music.note" : "film"
        }
        if Thumbnails.canThumbnail(fileName) { return "photo" }
        return "doc"
    }
}

private struct EntryRow: View {
    let entry: DirEntry

    var body: some View {
        HStack {
            Image(systemName: EntryIcon.name(isDir: entry.isDir, fileName: entry.name))
                .foregroundStyle(entry.isDir ? .blue : .secondary)
                .frame(width: 24)
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

/// A grid item: the thumbnail for an image, otherwise the item's icon.
private struct GridCell: View {
    let entry: DirEntry
    let path: String
    let isSelecting: Bool
    let isChecked: Bool
    let isHighlighted: Bool

    @Environment(SessionRegistry.self) private var sessionRegistry
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if isSelecting {
                    SelectionMark(isOn: isChecked)
                        .background(Circle().fill(Color(uiColor: .systemBackground)))
                        .padding(4)
                }
            }
            Text(entry.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            if !entry.isDir {
                Text(ByteFormat.string(entry.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .task(id: Thumbnails.key(path: path, entry: entry)) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: EntryIcon.name(isDir: entry.isDir, fileName: entry.name))
                .font(.system(size: 40))
                .foregroundStyle(entry.isDir ? Color.blue : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
        }
    }

    /// Decoded in memory only (ThumbnailCache); the session must still be
    /// the one this grid belongs to.
    private func loadThumbnail() async {
        guard !entry.isDir, Thumbnails.canThumbnail(entry.name), let session = sessionRegistry.session else {
            thumbnail = nil
            return
        }
        thumbnail = await Thumbnails.load(session: session, path: path, entry: entry)
    }
}

private struct SelectionMark: View {
    let isOn: Bool

    var body: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack {
            Image(systemName: EntryIcon.name(isDir: hit.isDir, fileName: hit.name))
                .foregroundStyle(hit.isDir ? .blue : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(hit.name)
                Text(hit.folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .contentShape(Rectangle())
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
