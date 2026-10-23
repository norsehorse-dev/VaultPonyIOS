import SwiftUI
import UIKit

// "Convert to VeraCrypt" (2.0.0 rc5, plan 6.2, D9). A TrueCrypt session is
// read-only; this makes a new VeraCrypt container with the create form and
// code, unlocks it, and has the core copy every file into it and check
// them. The TrueCrypt container is never written and never deleted.
//
// The job lives in SessionRegistry and RootView shows it over the whole
// app, so a lock that leaves the vault's screens still shows how the copy
// ended. While the copy runs it holds off the auto-lock (D13) and, in the
// background, keeps running inside a beginBackgroundTask window, as a bulk
// import does; when that window runs out it stops and locks. Any lock of
// the TrueCrypt vault stops the copy and locks the new container too.

@MainActor
@Observable
final class ConvertJob {
    enum Phase {
        /// summarizeTree is running.
        case counting
        /// Counting failed; the message says why.
        case unavailable(String)
        /// The create form, prefilled.
        case form(ConvertSetup)
        /// Unlocking the new container, then copying.
        case copying
        case finished(CopyReport)
        /// Stopped or failed after the new container was made. The message
        /// is nil when the user stopped it or a lock did.
        case stopped(String?)
    }

    private(set) var phase: Phase = .counting
    let progress = ConvertProgress()
    private(set) var isStopping = false
    /// The new vault is still unlocked and the TrueCrypt one too, so "Open
    /// new vault" can hand it over.
    private(set) var canOpenNewVault = false
    private(set) var deleteError: String?

    private let source: VaultSession
    private let sourceFacts: VolumeFacts
    private let sourceVault: SavedVault?
    private let sourceName: String
    @ObservationIgnored private weak var registry: SessionRegistry?
    private let vaultStore: VaultStore
    @ObservationIgnored private var cancel: UnlockCancel?
    @ObservationIgnored private var destination: VaultSession?
    @ObservationIgnored private var destinationFacts: VolumeFacts?
    @ObservationIgnored private var createdURL: URL?
    @ObservationIgnored private var createdBookmark: Data?
    @ObservationIgnored private var createdVault: SavedVault?
    @ObservationIgnored private var holdingLock = false
    @ObservationIgnored private var handingOver = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init(source: VaultSession, facts: VolumeFacts, sourceVault: SavedVault?, sourceName: String, registry: SessionRegistry, vaultStore: VaultStore) {
        self.source = source
        self.sourceFacts = facts
        self.sourceVault = sourceVault
        self.sourceName = sourceName
        self.registry = registry
        self.vaultStore = vaultStore
    }

    /// Starts a conversion of the open vault, if it is a TrueCrypt one and
    /// nothing else is running.
    static func begin(registry: SessionRegistry, vaultStore: VaultStore) {
        guard let session = registry.session,
              let facts = registry.facts, facts.truecrypt,
              registry.activeConvert == nil,
              registry.activeTransfer == nil else { return }
        let vault = vaultStore.vaults.first { $0.id == registry.vaultId }
        let label = vault.map { vaultStore.label(for: $0) } ?? ""
        let base = (label as NSString).deletingPathExtension
        let job = ConvertJob(
            source: session,
            facts: facts,
            sourceVault: vault,
            sourceName: base.isEmpty ? String(localized: "Vault", locale: LanguageOverride.locale) : base,
            registry: registry,
            vaultStore: vaultStore
        )
        registry.startConvert(job)
        Task { await job.count() }
    }

    // MARK: Counting

    private func count() async {
        do {
            let summary = try await Vault.summarizeTree(source)
            let bookmark = sourceVault?.bookmarkData
            let fileSize = await Task.detached { bookmark.flatMap { FdOpener.fileSize(bookmark: $0) } ?? 0 }.value
            guard isCurrent, case .counting = phase else { return }
            phase = .form(Self.setup(summary: summary, containerBytes: fileSize, name: sourceName, hidden: sourceFacts.hidden))
        } catch {
            guard isCurrent else { return }
            phase = .unavailable(Self.text(for: error) ?? "")
        }
    }

    /// Plan 6.2: the larger of the TrueCrypt file and the files plus 5% and
    /// 8 MiB, in whole MiB; never less than the files plus 8 MiB. FAT unless
    /// a file is over 4 GiB - 1.
    static func setup(summary: TreeSummary, containerBytes: UInt64, name: String, hidden: Bool) -> ConvertSetup {
        let mib: UInt64 = 1 << 20
        let padded = summary.bytes.addingReportingOverflow(summary.bytes / 20).partialValue
            .addingReportingOverflow(8 * mib).partialValue
        let wanted = max(containerBytes, padded)
        let suggestedMiB = wanted / mib + (wanted % mib == 0 ? 0 : 1)
        return ConvertSetup(
            name: name,
            suggestedMiB: suggestedMiB,
            minimumBytes: summary.bytes.addingReportingOverflow(8 * mib).partialValue,
            needsExFAT: summary.largestFile > 4_294_967_295,
            fromHiddenVolume: hidden
        )
    }

    // MARK: Copying

    /// The form made the container (and listed it). Unlock it and copy.
    func convert(into target: ConvertTarget) {
        createdURL = target.url
        createdBookmark = target.bookmark
        createdVault = target.vault
        guard isCurrent, registry?.session === source else {
            // The TrueCrypt vault locked while the container was being made.
            phase = .stopped(nil)
            return
        }
        let handle = UnlockCancel()
        cancel = handle
        isStopping = false
        phase = .copying
        holdLock()
        Task { await run(target, cancel: handle) }
    }

    private func run(_ target: ConvertTarget, cancel handle: UnlockCancel) async {
        do {
            let (fd, _) = try FdOpener.openForUnlock(bookmark: target.bookmark, writable: true)
            // The new container is never handed to Files.
            enableFilesHandoff(on: false)
            // Just made with this hash, so the search can skip the others.
            let dest = try await Vault.unlock(
                fd: fd,
                passphrase: target.passphrase,
                pim: target.pim,
                keyfiles: target.keyfiles,
                kdf: Vault.kdfFilter(forHash: target.prf) ?? .auto,
                cancel: handle,
                progress: nil
            )
            guard registry?.session === source, !isStopping else {
                dest.lock()
                throw VaultError.Cancelled
            }
            destination = dest
            let plan = try await Vault.planCopy(from: source, to: dest)
            progress.begin(files: plan.files, bytes: plan.bytes)
            let report = try await Vault.copyTree(from: source, to: dest, cancel: handle, progress: progress)
            // A lock right after the copy leaves only "Done".
            destinationFacts = try? await Vault.facts(dest)
            canOpenNewVault = destinationFacts != nil && destination != nil && registry?.session === source
            phase = .finished(report)
        } catch {
            phase = .stopped(Self.text(for: error))
        }
        cancel = nil
        // A lock that waited for the copy happens now, and finds the job
        // already finished or stopped.
        releaseLock()
        endBackgroundWindow()
    }

    /// The Stop button.
    func stop() {
        isStopping = true
        cancel?.cancel()
    }

    // MARK: Endings

    /// Locks the TrueCrypt vault and shows the new one in the browser.
    func openNewVault() {
        guard case .finished = phase, canOpenNewVault,
              let dest = destination, let facts = destinationFacts, let vault = createdVault,
              let registry else { return }
        handingOver = true
        registry.lock(keepingTransient: vault.id)
        handingOver = false
        destination = nil
        registry.adopt(dest, vaultId: vault.id, facts: facts, showInBrowser: true)
        vaultStore.touch(vault.id, filesystem: facts.filesystem)
        registry.endConvert()
    }

    /// "Done" after success: the TrueCrypt vault stays open, the new one
    /// locks (it is in the vault list).
    func done() {
        lockDestination()
        registry?.endConvert()
    }

    func keepNewContainer() {
        lockDestination()
        registry?.endConvert()
    }

    /// Locks the new container and deletes its file through the URL the
    /// save panel gave.
    func deleteNewContainer() {
        lockDestination()
        guard let url = createdURL, let bookmark = createdBookmark else {
            registry?.endConvert()
            return
        }
        do {
            try FdOpener.deleteCreatedFile(url: url, bookmark: bookmark)
            if let id = createdVault?.id {
                vaultStore.remove(id)
            }
            registry?.endConvert()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Closing before anything was made.
    func close() {
        lockDestination()
        registry?.endConvert()
    }

    // MARK: Locks and background

    /// SessionRegistry.lock, before the TrueCrypt vault's keys go: stop the
    /// copy and lock the new container. Before the form is done there is
    /// nothing to show, so the screen closes.
    func sourceWillLock() {
        guard !handingOver else { return }
        cancel?.cancel()
        lockDestination()
        switch phase {
        case .counting, .unavailable, .form:
            registry?.endConvert()
        case .finished:
            canOpenNewVault = false
        case .copying, .stopped:
            break
        }
    }

    /// RootView, as the app goes to the background: the copy keeps running
    /// for as long as iOS allows.
    func appDidEnterBackground() {
        guard case .copying = phase, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VaultPony convert") { [weak self] in
            MainActor.assumeIsolated {
                self?.backgroundTimeExpired()
            }
        }
    }

    func appDidBecomeActive() {
        endBackgroundWindow()
    }

    /// Out of background time with the copy still running: stop and lock
    /// rather than leave both vaults open with the auto-lock held off.
    private func backgroundTimeExpired() {
        cancel?.cancel()
        releaseLock()
        registry?.lock()
        endBackgroundWindow()
    }

    private var isCurrent: Bool {
        registry?.activeConvert === self
    }

    private func lockDestination() {
        guard let dest = destination else { return }
        destination = nil
        canOpenNewVault = false
        try? dest.flush()
        dest.lock()
    }

    private func holdLock() {
        guard !holdingLock else { return }
        holdingLock = true
        registry?.holdAutoLock()
    }

    private func releaseLock() {
        guard holdingLock else { return }
        holdingLock = false
        registry?.releaseAutoLock()
    }

    private func endBackgroundWindow() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Error text, or nil for a cancel (Stop, or a lock).
    private static func text(for error: Error) -> String? {
        if let error = error as? VaultError {
            if case .Cancelled = error { return nil }
            return error.message
        }
        return error.localizedDescription
    }
}

/// The conversion screen: counting, the create form, progress, and how it
/// ended.
struct ConvertView: View {
    let job: ConvertJob

    var body: some View {
        NavigationStack {
            content
        }
        .interactiveDismissDisabled()
    }

    @MainActor
    @ViewBuilder
    private var content: some View {
        switch job.phase {
        case .counting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Counting files…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Convert to VeraCrypt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { job.close() }
                }
            }
        case .unavailable(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(verbatim: message)
                    .multilineTextAlignment(.center)
                Button("Done") { job.close() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Convert to VeraCrypt")
            .navigationBarTitleDisplayMode(.inline)
        case .form(let setup):
            CreateContainerView(path: .constant(NavigationPath()), convert: setup) { target in
                Task { @MainActor in job.convert(into: target) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { job.close() }
                }
            }
        case .copying:
            copying
        case .finished(let report):
            finished(report)
        case .stopped(let message):
            stopped(message)
        }
    }

    @MainActor
    private var copying: some View {
        let progress = job.progress
        return VStack(spacing: 16) {
            Text("Copying \(Int(clamping: progress.filesDone)) of \(Int(clamping: progress.filesTotal)) files")
                .font(.headline)
            ProgressView(value: Double(progress.bytesDone), total: Double(max(progress.bytesTotal, 1)))
            Button("Stop", role: .destructive) {
                job.stop()
            }
            .disabled(job.isStopping)
        }
        .padding(24)
        .frame(maxWidth: 420, maxHeight: .infinity)
        .navigationTitle("Convert to VeraCrypt")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    @MainActor
    private func finished(_ report: CopyReport) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Converted. \(Int(clamping: report.files)) files and \(Int(clamping: report.folders)) folders copied and checked.")
                .multilineTextAlignment(.center)
            if report.renamed > 0 {
                Text("\(Int(clamping: report.renamed)) names were changed to work on FAT or exFAT.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if report.skipped > 0 {
                Text("\(Int(clamping: report.skipped)) links or special files were skipped.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if job.canOpenNewVault {
                Button {
                    job.openNewVault()
                } label: {
                    Text("Open new vault")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Done") {
                job.done()
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .navigationTitle("Convert to VeraCrypt")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func stopped(_ message: String?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Conversion stopped. The new container is incomplete.")
                .multilineTextAlignment(.center)
            if let message, !message.isEmpty {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let deleteError = job.deleteError {
                Text(verbatim: deleteError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button(role: .destructive) {
                job.deleteNewContainer()
            } label: {
                Text("Delete new container")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("Keep it") {
                job.keepNewContainer()
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .navigationTitle("Convert to VeraCrypt")
        .navigationBarTitleDisplayMode(.inline)
    }
}
