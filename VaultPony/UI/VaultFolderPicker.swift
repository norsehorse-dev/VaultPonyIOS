import SwiftUI

/// Picks a folder in the open vault (2.0.0 rc4): "Move to" for a browser
/// selection, "Choose a folder" for a share. Shows folders only, never the
/// app's or Files' temporary names. `canEnter` keeps a folder closed (Move
/// uses it so a folder is never moved into itself); `canPick` decides where
/// the action button works.
struct VaultFolderPicker: View {
    let title: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    var header: Text?
    var canEnter: (String) -> Bool = { _ in true }
    var canPick: (String) -> Bool = { _ in true }
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var stack: [String] = []

    var body: some View {
        NavigationStack(path: $stack) {
            level("/")
                .navigationDestination(for: String.self) { folder in
                    level(folder)
                }
        }
    }

    private func level(_ folder: String) -> some View {
        FolderLevel(
            folder: folder,
            title: title,
            actionTitle: actionTitle,
            header: header,
            canEnter: canEnter,
            canPick: canPick,
            onPick: onPick,
            onCancel: onCancel
        )
    }
}

private struct FolderLevel: View {
    let folder: String
    let title: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let header: Text?
    let canEnter: (String) -> Bool
    let canPick: (String) -> Bool
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @Environment(SessionRegistry.self) private var sessionRegistry
    @State private var folders: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else {
                    ForEach(folders, id: \.self) { name in
                        let child = VaultPath.join(folder, name)
                        NavigationLink(value: child) {
                            Label {
                                Text(verbatim: name)
                            } icon: {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .disabled(!canEnter(child))
                    }
                }
            } header: {
                if let header {
                    header
                }
            }
        }
        .navigationTitle(folder == "/" ? Text(title) : Text(verbatim: VaultPath.name(folder)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(actionTitle) {
                    onPick(folder)
                }
                .disabled(isLoading || errorMessage != nil || !canPick(folder))
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        guard let session = sessionRegistry.session else {
            errorMessage = String(localized: "Vault is locked.", locale: LanguageOverride.locale)
            isLoading = false
            return
        }
        do {
            folders = try await Vault.list(session, path: folder)
                .filter { $0.isDir && !FilesNaming.isHiddenFromListing($0.name) && $0.name != "." && $0.name != ".." }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            errorMessage = nil
        } catch let error as VaultError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
