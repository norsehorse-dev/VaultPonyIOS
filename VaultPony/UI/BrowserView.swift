import SwiftUI

/// Identifies a file push target in the shared NavigationPath (see
/// HomeView's navigationDestination(for: FileTarget.self)).
struct FileTarget: Hashable {
    let path: String
    let name: String
}

struct BrowserView: View {
    let path: String

    @Environment(SessionRegistry.self) private var sessionRegistry
    @State private var entries: [DirEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

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
            }
        }
        .navigationTitle(titleForPath)
        .task { await load() }
        .refreshable { await load() }
        .onAppear { sessionRegistry.markActivity() }
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
