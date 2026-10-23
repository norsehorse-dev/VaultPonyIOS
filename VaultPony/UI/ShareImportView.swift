import SwiftUI
import UniformTypeIdentifiers

/// Where a share goes (2.0.0 rc4, plan 5.1). RootView shows this as a sheet
/// while `ShareInbox` holds a claimed share: a folder in the unlocked vault,
/// or with nothing unlocked, the vault list to unlock one from. Picking a
/// vault closes the sheet and opens that vault's unlock screen; the sheet
/// comes back with the folder picker once it is unlocked.
struct ShareImportView: View {
    let share: IncomingShare

    @Environment(VaultStore.self) private var vaultStore
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(ShareInbox.self) private var shareInbox
    @Environment(AppPrefs.self) private var appPrefs

    @State private var isPreparing = false
    @State private var shortfall: (needed: UInt64, free: UInt64)?
    @State private var showVaultImporter = false
    @State private var openError: String?

    private var canWrite: Bool {
        sessionRegistry.facts?.writable == true
    }

    /// "N files to save", and on a read-only volume why Save here is off.
    private var pickerHeader: Text {
        let count = Text("\(share.files.count) files to save")
        guard !canWrite else { return count }
        return count + Text(verbatim: "\n") + Text("Read-only")
    }

    var body: some View {
        Group {
            if sessionRegistry.session != nil {
                VaultFolderPicker(
                    title: "Choose a folder",
                    actionTitle: "Save here",
                    header: pickerHeader,
                    canPick: { _ in canWrite },
                    onPick: { folder in
                        Task { await save(into: folder) }
                    },
                    onCancel: { shareInbox.discard() }
                )
                .disabled(isPreparing)
                .overlay {
                    if isPreparing {
                        ProgressView()
                            .padding()
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                vaultList
            }
        }
        .alert("Not Enough Space", isPresented: Binding(
            get: { shortfall != nil },
            set: { if !$0 { shortfall = nil } }
        )) {
            Button("OK", role: .cancel) { shortfall = nil }
        } message: {
            if let shortfall {
                Text("These files need \(ByteFormat.string(shortfall.needed)) but the vault has \(ByteFormat.string(shortfall.free)) free.")
            }
        }
    }

    /// Vaults a share can be saved into. One last opened in TrueCrypt mode
    /// opens read-only, so it isn't offered (2.0.0 rc5).
    private var shareTargets: [SavedVault] {
        vaultStore.vaults.filter { $0.rememberedTrueCrypt != true }
    }

    private var vaultList: some View {
        NavigationStack {
            List {
                if !shareTargets.isEmpty {
                    Section {
                        ForEach(shareTargets) { vault in
                            Button {
                                shareInbox.awaitingUnlock = true
                                shareInbox.vaultToUnlock = vault
                            } label: {
                                Label {
                                    Text(verbatim: vaultStore.label(for: vault))
                                        .foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: "lock.doc")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Unlock a vault to save these files.")
                    }
                }
                // A vault that isn't in the list (it may keep nothing):
                // open its file, then unlock it. The share stays waiting.
                Section {
                    Button {
                        showVaultImporter = true
                    } label: {
                        Label("Open Vault", systemImage: "doc.badge.plus")
                    }
                } header: {
                    if shareTargets.isEmpty {
                        Text("Unlock a vault to save these files.")
                    }
                }
            }
            .navigationTitle("VaultPony")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        shareInbox.discard()
                    }
                }
            }
            .fileImporter(isPresented: $showVaultImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                openVault(result)
            }
            .alert("Couldn't Open File", isPresented: Binding(
                get: { openError != nil },
                set: { if !$0 { openError = nil } }
            )) {
                Button("OK") { openError = nil }
            } message: {
                Text(openError ?? "")
            }
        }
    }

    /// Adds the picked container to the list the way Home's Open Vault
    /// does (under the vault list setting in effect), then goes to its
    /// unlock screen. The sheet comes back once it is unlocked.
    private func openVault(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let (fd, bookmark) = try FdOpener.openForImport(url: url, writable: false)
            close(fd)
            let vault = vaultStore.add(bookmarkData: bookmark, displayName: url.lastPathComponent, mode: appPrefs.effectiveVaultListMode)
            shareInbox.awaitingUnlock = true
            shareInbox.vaultToUnlock = vault
        } catch {
            openError = error.localizedDescription
        }
    }

    /// Plans the import into `folder` (names that exist keep both copies,
    /// files FAT can't hold are skipped), checks space, and starts the bulk
    /// import. The claimed files are deleted when it ends.
    @MainActor
    private func save(into folder: String) async {
        guard let session = sessionRegistry.session, sessionRegistry.activeTransfer == nil, !isPreparing else { return }
        isPreparing = true
        let maxFileBytes = sessionRegistry.facts?.maxFileBytes
        let space = try? await Vault.space(session)
        let files = share.files
        let walked = await Task.detached { ImportWalker.walk(files) }.value
        let plan = await ImportWalker.plan(
            session: session,
            items: walked.items,
            destination: folder,
            policy: .keepBoth,
            maxFileBytes: maxFileBytes,
            clusterBytes: space?.clusterBytes ?? 0
        )
        isPreparing = false
        guard sessionRegistry.session === session else { return }
        if let free = space?.freeBytes, !plan.fits(freeBytes: free) {
            shortfall = (plan.bytesNeeded, free)
            return
        }
        let share = self.share
        let inbox = shareInbox
        inbox.beginImport(share)
        let transfer = BulkTransfer(
            kind: .importing,
            steps: ImportWalker.steps(for: plan, sources: walked.sources),
            counts: BulkTransfer.Counts(
                skipped: plan.tooLargeCount + plan.skippedExistingCount,
                renamed: plan.renamedCount,
                keptBoth: plan.keptBothCount
            ),
            session: session,
            registry: sessionRegistry,
            scopedURLs: [],
            onFinish: { inbox.importEnded(share) }
        )
        transfer.start()
    }
}
