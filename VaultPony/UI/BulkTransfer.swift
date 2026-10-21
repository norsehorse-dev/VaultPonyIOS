import Foundation
import SwiftUI
import UIKit

// Bulk import and folder export (2.0.0, issue #3). TransferPlanner.swift
// decides names and checks space; this file walks the sources, runs the
// copy in 1 MiB chunks through the same Vault.create / writeAt / flush path
// the single-file import used, and handles the app going to the background.
//
// Backgrounding: the copy finishes the file it is on inside a
// beginBackgroundTask window, flushes, then pauses. While it is copying it
// holds off SessionRegistry's auto-lock, so the vault never locks with a
// half-written file. Back in the foreground it resumes if the vault is
// still unlocked; if it was locked meanwhile it ends and shows what was
// copied.

/// One step of a bulk copy, in run order (a folder before its contents).
enum TransferStep: Sendable {
    /// Deletes partial files an interrupted import left in this vault folder.
    case removePartials(folder: String)
    case vaultFolder(path: String)
    case importFile(source: URL, destPath: String, size: UInt64, replaces: Bool)
    case localFolder(url: URL)
    case exportFile(sourcePath: String, dest: URL, size: UInt64)

    var isFile: Bool {
        switch self {
        case .importFile, .exportFile: return true
        case .removePartials, .vaultFolder, .localFolder: return false
        }
    }

    var size: UInt64 {
        switch self {
        case .importFile(_, _, let size, _), .exportFile(_, _, let size): return size
        case .removePartials, .vaultFolder, .localFolder: return 0
        }
    }

    var displayName: String {
        switch self {
        case .removePartials: return ""
        case .vaultFolder(let path): return (path as NSString).lastPathComponent
        case .importFile(let source, _, _, _): return source.lastPathComponent
        case .localFolder(let url): return url.lastPathComponent
        case .exportFile(let sourcePath, _, _): return (sourcePath as NSString).lastPathComponent
        }
    }
}

enum StepOutcome: Sendable {
    case done
    /// The source file couldn't be read. Counted as skipped.
    case skipped
    /// Stopped at a chunk boundary (Cancel, or background time ran out).
    /// The partial file has been removed.
    case interrupted
}

/// Shown once a transfer ends. The first summary line is the title.
struct TransferSummary: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Stop requests read from the copy loop's thread.
final class TransferFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var interrupted = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    var shouldStop: Bool { lock.withLock { cancelled || interrupted } }

    func cancel() { lock.withLock { cancelled = true } }
    func interrupt() { lock.withLock { interrupted = true } }
    func clearInterrupt() { lock.withLock { interrupted = false } }
}

// MARK: - Walking the sources

enum ImportWalker {
    /// Turns the picked files and folders into planner items, folders
    /// before their contents, with each item's source URL alongside.
    /// Symlinks and other special files are left out.
    static func walk(_ roots: [URL]) -> (items: [TransferItem], sources: [URL]) {
        var items: [TransferItem] = []
        var sources: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let keySet = Set(keys)

        for root in roots {
            let name = root.lastPathComponent
            let values = try? root.resourceValues(forKeys: keySet)
            guard values?.isDirectory == true else {
                items.append(TransferItem([name], size: UInt64(max(values?.fileSize ?? 0, 0))))
                sources.append(root)
                continue
            }

            items.append(TransferItem([name], isDirectory: true))
            sources.append(root)
            let base = root.standardizedFileURL.path(percentEncoded: false)
            let prefix = base.hasSuffix("/") ? base : base + "/"
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walker {
                let full = url.standardizedFileURL.path(percentEncoded: false)
                guard full.hasPrefix(prefix) else { continue }
                let relative = full.dropFirst(prefix.count).split(separator: "/").map(String.init)
                guard !relative.isEmpty else { continue }
                let v = try? url.resourceValues(forKeys: keySet)
                if v?.isDirectory == true {
                    items.append(TransferItem([name] + relative, isDirectory: true))
                } else if v?.isRegularFile == true {
                    items.append(TransferItem([name] + relative, size: UInt64(max(v?.fileSize ?? 0, 0))))
                } else {
                    continue
                }
                sources.append(url)
            }
        }
        return (items, sources)
    }

    /// The plan as run order: clean leftovers out of the folders that
    /// already exist, then each new folder and file in the order the walk
    /// found them.
    static func steps(for plan: TransferPlan, sources: [URL]) -> [TransferStep] {
        let cleanup = plan.existingFolders.map { TransferStep.removePartials(folder: $0) }
        var ordered: [(Int, TransferStep)] = plan.directories.map {
            ($0.sourceIndex, TransferStep.vaultFolder(path: $0.destPath))
        }
        ordered += plan.files.map {
            ($0.sourceIndex, TransferStep.importFile(source: sources[$0.sourceIndex], destPath: $0.destPath, size: $0.size, replaces: $0.replacesExisting))
        }
        return cleanup + ordered.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}

enum ExportWalker {
    /// Recreates `vaultFolder` as `localFolder`: the folder itself, then
    /// everything inside it, recursively.
    ///
    /// Vault names never reach a local path as they are: a crafted
    /// container could hold "..", "/" or names that differ only in case.
    /// Each name goes through `TransferNaming.sanitize` (which also turns
    /// "." and ".." into "_"), and names that meet inside one folder get
    /// "name (1)". `localFolder` itself must be new; the copy creates
    /// every folder and file exclusively, so nothing on disk is overwritten.
    static func steps(session: VaultSession, vaultFolder: String, localFolder: URL) async throws -> [TransferStep] {
        var steps: [TransferStep] = [.localFolder(url: localFolder)]
        let entries = try await Vault.list(session, path: vaultFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var used: Set<String> = []
        for entry in entries {
            let vaultPath = TransferPlanner.join(vaultFolder, entry.name)
            var name = TransferNaming.sanitize(entry.name)
            if used.contains(TransferNaming.fold(name)) {
                name = TransferNaming.keepBothName(for: name, isDirectory: entry.isDir) { used.contains(TransferNaming.fold($0)) }
            }
            used.insert(TransferNaming.fold(name))
            if entry.isDir {
                let child = localFolder.appending(path: name, directoryHint: .isDirectory)
                steps += try await self.steps(session: session, vaultFolder: vaultPath, localFolder: child)
            } else {
                let dest = localFolder.appending(path: name, directoryHint: .notDirectory)
                steps.append(.exportFile(sourcePath: vaultPath, dest: dest, size: entry.size))
            }
        }
        return steps
    }
}

// MARK: - Copying one file

enum TransferIO {
    static let chunkBytes = 1 << 20

    /// Copies `source` into the vault at `destPath`. The copy is written
    /// under a temporary ".vaultpony-<random>.part" name beside it and
    /// renamed into place only when complete, so an app killed mid-file
    /// never leaves a partial file under the real name. With `replaces`,
    /// the old file is removed just before that rename, so a cancel or an
    /// unreadable source leaves the original alone.
    static func importFile(
        session: VaultSession,
        source: URL,
        destPath: String,
        replaces: Bool,
        flags: TransferFlags,
        progress: @Sendable (UInt64) async -> Void
    ) async throws -> StepOutcome {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            return .skipped
        }
        defer { try? input.close() }

        let writePath = partialPath(beside: destPath)
        try await Vault.create(session, path: writePath)
        var offset: UInt64 = 0
        while true {
            if flags.shouldStop {
                try? await Vault.remove(session, path: writePath)
                return .interrupted
            }
            let chunk: Data
            do {
                chunk = try autoreleasepool { try input.read(upToCount: chunkBytes) } ?? Data()
            } catch {
                try? await Vault.remove(session, path: writePath)
                return .skipped
            }
            if chunk.isEmpty { break }
            do {
                try await Vault.writeAt(session, path: writePath, offset: offset, data: chunk)
            } catch {
                try? await Vault.remove(session, path: writePath)
                throw error
            }
            offset += UInt64(chunk.count)
            await progress(offset)
        }
        if replaces {
            try await Vault.remove(session, path: destPath)
        }
        try await Vault.rename(session, from: writePath, to: destPath)
        return .done
    }

    /// Copies the vault file `sourcePath` out to `dest`, which must not
    /// exist yet (created with O_EXCL, never truncating a file).
    static func exportFile(
        session: VaultSession,
        sourcePath: String,
        dest: URL,
        flags: TransferFlags,
        progress: @Sendable (UInt64) async -> Void
    ) async throws -> StepOutcome {
        let fd = open(dest.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var offset: UInt64 = 0
        do {
            while true {
                if flags.shouldStop {
                    try? output.close()
                    try? FileManager.default.removeItem(at: dest)
                    return .interrupted
                }
                let data = try await Vault.readAt(session, path: sourcePath, offset: offset, len: UInt32(chunkBytes))
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                offset += UInt64(data.count)
                await progress(offset)
                if data.count < chunkBytes { break }
            }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return .done
    }

    /// A temporary name in the same folder for a file being imported.
    static func partialPath(beside path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let name = TransferNaming.partialPrefix + UUID().uuidString.prefix(8).lowercased() + TransferNaming.partialSuffix
        return TransferPlanner.join(folder.isEmpty ? "/" : folder, name)
    }

    /// Deletes leftover partial files in a vault folder. Best effort.
    static func removePartials(session: VaultSession, folder: String) async {
        guard let entries = try? await Vault.list(session, path: folder) else { return }
        for entry in entries where !entry.isDir && TransferNaming.isPartialName(entry.name) {
            try? await Vault.remove(session, path: TransferPlanner.join(folder, entry.name))
        }
    }
}

// MARK: - Running a transfer

@MainActor
@Observable
final class BulkTransfer {
    enum Kind {
        case importing
        case exporting
    }

    /// What the pre-flight decided, carried to the summary.
    struct Counts {
        var skipped = 0
        var renamed = 0
        var keptBoth = 0
    }

    private enum StopReason {
        case cancelled
        case locked
        case failed(String)
    }

    let kind: Kind
    let fileTotal: Int
    let bytesTotal: UInt64
    private(set) var filesDone = 0
    private(set) var bytesDone: UInt64 = 0
    private(set) var currentName = ""
    private(set) var isCancelling = false

    private let steps: [TransferStep]
    private let session: VaultSession
    private let scopedURLs: [URL]
    private let flags = TransferFlags()
    @ObservationIgnored private weak var registry: SessionRegistry?
    @ObservationIgnored private var counts: Counts
    @ObservationIgnored private var completedBytes: UInt64 = 0
    @ObservationIgnored private var pauseRequested = false
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var holdingLock = false
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var resumeWaiter: CheckedContinuation<Void, Never>?

    /// `scopedURLs` are security-scoped URLs this transfer started
    /// accessing; it stops accessing them when it ends.
    init(kind: Kind, steps: [TransferStep], counts: Counts, session: VaultSession, registry: SessionRegistry, scopedURLs: [URL]) {
        self.kind = kind
        self.steps = steps
        self.counts = counts
        self.session = session
        self.registry = registry
        self.scopedURLs = scopedURLs
        let files = steps.filter(\.isFile)
        self.fileTotal = files.count
        self.bytesTotal = files.reduce(0) { $0 + $1.size }
    }

    func start() {
        registry?.startTransfer(self)
        holdLock()
        Task { await run() }
    }

    func cancel() {
        isCancelling = true
        flags.cancel()
        resumeIfPaused()
    }

    /// RootView calls this before SessionRegistry starts its own
    /// background handling, so the hold is in place first.
    func appDidEnterBackground() {
        guard !finished else { return }
        inBackground = true
        pauseRequested = true
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VaultPony copy") { [weak self] in
            MainActor.assumeIsolated {
                self?.backgroundTimeExpired()
            }
        }
    }

    /// RootView calls this after SessionRegistry has applied any auto-lock
    /// that came due while the app was away.
    func appDidBecomeActive() {
        inBackground = false
        endBackgroundWindow()
        if resumeWaiter != nil {
            resumeIfPaused()
            return
        }
        // Back before the current file finished. Carry on, unless a lock
        // is waiting for this file to end or already happened (the Home
        // Screen quick action locks as the app comes back).
        if registry?.lockPending != true, registry?.session === session {
            pauseRequested = false
            flags.clearInterrupt()
        }
    }

    /// SessionRegistry.lockAll calls this just before it locks: stop at the
    /// next chunk boundary, and wake a copy paused in the background so it
    /// sees the lock and ends with what was copied.
    func stopForLock() {
        guard !finished else { return }
        flags.interrupt()
        resumeIfPaused()
    }

    private func backgroundTimeExpired() {
        // Out of background time with a file still copying. The app is
        // about to be suspended, so lock now rather than leave the vault
        // open with the auto-lock held off. lock() flushes and waits on the
        // core's session mutex for the chunk in flight. The half-written
        // ".part" file is deleted by the next import into that folder; the
        // copy ends with "stopped" when the app runs again.
        flags.interrupt()
        registry?.lock()
        endBackgroundWindow()
    }

    private func run() async {
        var stop: StopReason?
        var index = 0
        loop: while index < steps.count {
            if flags.isCancelled {
                stop = .cancelled
                break loop
            }
            if pauseRequested, let reason = await pauseAtFileBoundary() {
                stop = reason
                break loop
            }
            guard registry?.session === session else {
                stop = .locked
                break loop
            }
            let step = steps[index]
            currentName = step.displayName
            do {
                switch try await perform(step) {
                case .done:
                    if step.isFile { filesDone += 1 }
                    completedBytes += step.size
                    index += 1
                case .skipped:
                    counts.skipped += 1
                    completedBytes += step.size
                    index += 1
                case .interrupted:
                    if flags.isCancelled {
                        stop = .cancelled
                        break loop
                    }
                    // Background time ran out: this file runs again later.
                }
                bytesDone = completedBytes
            } catch {
                if registry?.session !== session {
                    // Locked under the copy (background time ran out).
                    stop = .locked
                } else {
                    stop = .failed((error as? VaultError)?.message ?? error.localizedDescription)
                }
                break loop
            }
        }
        if registry?.session === session {
            try? await Vault.flush(session)
        }
        finish(stop)
    }

    private func perform(_ step: TransferStep) async throws -> StepOutcome {
        let session = self.session
        let flags = self.flags
        let progress: @Sendable (UInt64) async -> Void = { [weak self] written in
            await self?.fileProgress(written)
        }
        switch step {
        case .removePartials(let folder):
            await TransferIO.removePartials(session: session, folder: folder)
            return .done
        case .vaultFolder(let path):
            try await Vault.mkdir(session, path: path)
            return .done
        case .importFile(let source, let destPath, _, let replaces):
            return try await TransferIO.importFile(session: session, source: source, destPath: destPath, replaces: replaces, flags: flags, progress: progress)
        case .localFolder(let url):
            // Not withIntermediateDirectories: an existing folder is an
            // error rather than something to write into.
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return .done
        case .exportFile(let sourcePath, let dest, _):
            return try await TransferIO.exportFile(session: session, sourcePath: sourcePath, dest: dest, flags: flags, progress: progress)
        }
    }

    private func fileProgress(_ written: UInt64) {
        bytesDone = min(completedBytes + written, bytesTotal)
    }

    /// Between files, with a pause requested: flush, let go of the
    /// auto-lock hold (a lock that waited for this file happens now), and
    /// wait for the foreground if still in the background. Returns why to
    /// stop, or nil to carry on.
    private func pauseAtFileBoundary() async -> StopReason? {
        pauseRequested = false
        flags.clearInterrupt()
        try? await Vault.flush(session)
        releaseLock()
        endBackgroundWindow()
        guard registry?.session === session else { return .locked }
        if inBackground {
            await withCheckedContinuation { resumeWaiter = $0 }
            guard registry?.session === session else { return .locked }
        }
        if flags.isCancelled { return .cancelled }
        holdLock()
        return nil
    }

    private func resumeIfPaused() {
        guard let waiter = resumeWaiter else { return }
        resumeWaiter = nil
        waiter.resume()
    }

    private func finish(_ stop: StopReason?) {
        finished = true
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        registry?.transferFinished(summary(for: stop))
        releaseLock()
        endBackgroundWindow()
    }

    private func summary(for stop: StopReason?) -> TransferSummary {
        let locale = LanguageOverride.locale
        var lines: [String] = []
        switch kind {
        case .importing:
            if stop == nil {
                lines.append(String(localized: "Imported \(filesDone) files.", locale: locale))
                if counts.skipped > 0 {
                    lines.append(String(localized: "Skipped \(counts.skipped).", locale: locale))
                }
                if counts.renamed > 0 {
                    lines.append(String(localized: "Renamed \(counts.renamed) to fit the vault's filesystem.", locale: locale))
                }
                if counts.keptBoth > 0 {
                    lines.append(String(localized: "\(counts.keptBoth) kept both copies.", locale: locale))
                }
            } else {
                lines.append(String(localized: "Import stopped. \(filesDone) of \(fileTotal) files were copied.", locale: locale))
            }
        case .exporting:
            if stop == nil {
                lines.append(String(localized: "Exported \(filesDone) files.", locale: locale))
            } else {
                lines.append(String(localized: "Export stopped. \(filesDone) of \(fileTotal) files were copied.", locale: locale))
            }
        }
        if case .failed(let message) = stop {
            lines.append(message)
        }
        return TransferSummary(title: lines[0], message: lines.dropFirst().joined(separator: "\n"))
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
}

// MARK: - Progress UI

/// Covers the app while a transfer runs: count, current file, bytes, and
/// Cancel. RootView shows it so it survives navigation.
struct TransferProgressOverlay: View {
    let transfer: BulkTransfer

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                if transfer.fileTotal > 0 {
                    Text("Copying \(min(transfer.filesDone + 1, transfer.fileTotal)) of \(transfer.fileTotal)")
                        .font(.headline)
                }
                Text(verbatim: transfer.currentName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: Double(transfer.bytesDone), total: Double(max(transfer.bytesTotal, 1)))
                Button("Cancel", role: .cancel) {
                    transfer.cancel()
                }
                .disabled(transfer.isCancelling)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(32)
        }
        .accessibilityAddTraits(.isModal)
    }
}
