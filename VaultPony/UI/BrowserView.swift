import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Identifies a file push target in the shared NavigationPath (see
/// HomeView's navigationDestination(for: FileTarget.self)).
struct FileTarget: Hashable {
    let path: String
    let name: String
}

struct BrowserView: View {
    let path: String

    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(AppPrefs.self) private var appPrefs
    @State private var entries: [DirEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""

    @State private var showFileImporter = false
    @State private var isBusy = false

    @State private var entryToRename: DirEntry?
    @State private var renameText = ""

    @State private var pendingExportEntry: DirEntry?
    @State private var exportURL: URL?
    @State private var showExportSheet = false

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
        .safeAreaInset(edge: .top) {
            if sessionRegistry.isCopyMode {
                copyModeBanner
            }
        }
        .navigationTitle(titleForPath)
        .toolbar {
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
                        showFileImporter = true
                    } label: {
                        Label("Import Files", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!canWrite)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onAppear { sessionRegistry.markActivity() }
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
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let urls = try? result.get() else { return }
            Task { await importFiles(urls) }
        }
        .sheet(isPresented: $showExportSheet) {
            if let exportURL {
                ShareSheet(activityItems: [exportURL])
            }
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

    @ViewBuilder
    private func row(for entry: DirEntry) -> some View {
        Group {
            if entry.isDir {
                NavigationLink(value: childPath(entry.name)) {
                    EntryRow(entry: entry)
                }
            } else {
                NavigationLink(value: FileTarget(path: childPath(entry.name), name: entry.name)) {
                    EntryRow(entry: entry)
                }
            }
        }
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
            if !entry.isDir {
                Button {
                    if appPrefs.noTraceMode {
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
    }

    private var titleForPath: String {
        guard path != "/" else { return "Vault" }
        return (path as NSString).lastPathComponent
    }

    private func childPath(_ name: String) -> String {
        path == "/" ? "/\(name)" : "\(path)/\(name)"
    }

    private func load() async {
        guard let session = sessionRegistry.session else {
            errorMessage = "Vault is locked."
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
        } catch let error as VaultError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Chunked copy-in: reads each picked file from its (possibly
    /// security-scoped) URL in bounded pieces and writes them into the
    /// vault, so a large import never balloons memory.
    private func importFiles(_ urls: [URL]) async {
        guard let session = sessionRegistry.session else { return }
        isBusy = true
        defer { isBusy = false }

        let chunkSize = 4 << 20 // 4 MiB

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            guard let input = InputStream(url: url) else { continue }
            input.open()
            defer { input.close() }

            let destPath = childPath(url.lastPathComponent)
            do {
                try await Vault.create(session, path: destPath)
                var offset: UInt64 = 0
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                while true {
                    let n = buffer.withUnsafeMutableBytes { raw -> Int in
                        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                        return input.read(base, maxLength: chunkSize)
                    }
                    if n <= 0 { break }
                    let chunk = Data(buffer[0..<n])
                    try await Vault.writeAt(session, path: destPath, offset: offset, data: chunk)
                    offset += UInt64(n)
                }
                try await Vault.flush(session)
            } catch let error as VaultError {
                errorMessage = error.message
                break
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        await load()
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
