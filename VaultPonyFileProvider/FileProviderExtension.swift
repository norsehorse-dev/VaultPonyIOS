import FileProvider
import Foundation
import os

/// VaultPony in the Files app (2.0.0 rc3, plan 4.2 and D18 to D20).
///
/// The non-replicated File Provider model: VaultPony decides where opened
/// files are written out (this domain's folder in the app group, `.complete`
/// protection, excluded from backup) and deletes them when they are no
/// longer used and at lock. The extension never sees a password: the app
/// unlocks, then hands over the session over `VaultFilesXPC`.
///
/// Materialized files live at `<domain storage>/<item id split in parts>/
/// <file name>`, so a URL maps back to its identifier without any table.
final class FileProviderExtension: NSFileProviderExtension {
    private static let idPartLength = 200

    override init() {
        _ = FileProviderExtension.configureProcess
        super.init()
    }

    /// Once per process: this process lives within a ~20 MB budget.
    private static let configureProcess: Void = {
        setLowMemoryProfile(on: true)
    }()

    private var activeVault: FilesVault {
        get throws {
            guard let domain else { throw NSFileProviderError(.notAuthenticated) }
            return FilesVault.forDomain(domain)
        }
    }

    // MARK: - Items and URLs

    override func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        let vault = try activeVault
        if identifier == .workingSet {
            throw NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)
        }
        return try vault.item(for: try vault.path(for: identifier))
    }

    override func urlForItem(withPersistentIdentifier identifier: NSFileProviderItemIdentifier) -> URL? {
        guard let vault = try? activeVault else { return nil }
        if identifier == .rootContainer {
            return vault.storage
        }
        guard let codec = vault.codecIfOpen(), let path = codec.path(for: identifier) else {
            return nil
        }
        var url = vault.storage
        for part in Self.parts(of: identifier.rawValue) {
            url.appendPathComponent(part, isDirectory: true)
        }
        return url.appendingPathComponent(VaultPath.name(path), isDirectory: false)
    }

    override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
        guard let vault = try? activeVault else { return nil }
        // Coordinated URLs may spell the container /private/var or /var.
        let base = vault.storage.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let comps = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard comps.count > base.count, Array(comps.prefix(base.count)) == base else {
            return comps == base ? .rootContainer : nil
        }
        let middle = comps.dropFirst(base.count).dropLast()
        guard !middle.isEmpty else { return nil }
        return NSFileProviderItemIdentifier(middle.joined())
    }

    private static func parts(of raw: String) -> [String] {
        var out: [String] = []
        var rest = Substring(raw)
        while !rest.isEmpty {
            out.append(String(rest.prefix(idPartLength)))
            rest = rest.dropFirst(idPartLength)
        }
        return out
    }

    // MARK: - Contents

    override func providePlaceholder(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let identifier = persistentIdentifierForItem(at: url) else {
                throw NSFileProviderError(.noSuchItem)
            }
            let item = try item(for: identifier)
            let placeholder = NSFileProviderManager.placeholderURL(for: url)
            try activeVault.makeDirectory(url.deletingLastPathComponent())
            try NSFileProviderManager.writePlaceholder(at: placeholder, withMetadata: item)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    override func startProvidingItem(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let vault = try? activeVault else {
            completionHandler(NSFileProviderError(.notAuthenticated))
            return
        }
        vault.fileQueue.async { [self] in
            do {
                guard let identifier = persistentIdentifierForItem(at: url) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let path = try vault.path(for: identifier)
                try vault.materialize(path: path, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    /// Another app saved over a file it opened from Files.
    override func itemChanged(at url: URL) {
        (try? activeVault)?.scheduleEdit(url: url)
    }

    /// No app uses the file any more: a save still waiting goes in, then
    /// the plaintext copy is deleted.
    override func stopProvidingItem(at url: URL) {
        guard let vault = try? activeVault else { return }
        vault.fileQueue.async {
            vault.dematerialize(url: url)
        }
    }

    // MARK: - Enumeration

    override func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier) throws -> NSFileProviderEnumerator {
        let vault = try activeVault
        if containerItemIdentifier == .workingSet {
            return EmptyEnumerator()
        }
        let path = try vault.path(for: containerItemIdentifier)
        if path != "/" {
            guard try vault.stat(path).isDir else {
                throw NSFileProviderError(.noSuchItem)
            }
        } else {
            // Locked: this is what makes Files show the "Open VaultPony"
            // screen from the FileProviderUI extension.
            _ = try vault.open()
        }
        return FileProviderEnumerator(vault: vault, folder: path)
    }

    // MARK: - Actions

    override func importDocument(at fileURL: URL, toParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            do {
                let vault = try activeVault
                try vault.requireWritable()
                let folder = try vault.path(for: parentItemIdentifier)
                let path = try importTree(fileURL, into: folder, vault: vault)
                completionHandler(try vault.item(for: path), nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    /// Copies a file, or a folder with everything in it, into `folder`.
    /// Existing names are kept and the new item becomes "name (1)" (D6).
    private func importTree(_ url: URL, into folder: String, vault: FilesVault) throws -> String {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let name = try vault.uniqueName(url.lastPathComponent, in: folder)
        let path = VaultPath.join(folder, name)
        if isDir {
            try vault.call(write: true) { try $0.mkdir(path: path) }
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            for child in children {
                _ = try importTree(child, into: path, vault: vault)
            }
            return path
        }
        return try vault.store(localFile: url, at: path, replacing: false)
    }

    override func createDirectory(withName directoryName: String, inParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) {
        do {
            let vault = try activeVault
            try vault.requireWritable()
            let folder = try vault.path(for: parentItemIdentifier)
            let path = VaultPath.join(folder, directoryName)
            if try vault.exists(path) {
                throw NSError.fileProviderErrorForCollision(with: try vault.item(for: path))
            }
            try vault.call(write: true) { try $0.mkdir(path: path) }
            completionHandler(try vault.item(for: path), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    override func renameItem(withIdentifier itemIdentifier: NSFileProviderItemIdentifier, toName itemName: String, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) {
        do {
            let vault = try activeVault
            let path = try vault.path(for: itemIdentifier)
            let target = VaultPath.join(VaultPath.parent(path), itemName)
            try move(path, to: target, vault: vault)
            completionHandler(try vault.item(for: target), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    override func reparentItem(withIdentifier itemIdentifier: NSFileProviderItemIdentifier, toParentItemWithIdentifier parentItemIdentifier: NSFileProviderItemIdentifier, newName: String?, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) {
        do {
            let vault = try activeVault
            let path = try vault.path(for: itemIdentifier)
            let folder = try vault.path(for: parentItemIdentifier)
            let target = VaultPath.join(folder, newName ?? VaultPath.name(path))
            try move(path, to: target, vault: vault)
            completionHandler(try vault.item(for: target), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    private func move(_ path: String, to target: String, vault: FilesVault) throws {
        guard path != "/" else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        try vault.requireWritable()
        if target == path { return }
        // A case-only rename is the same entry on FAT and exFAT.
        if target.lowercased() != path.lowercased(), try vault.exists(target) {
            throw NSError.fileProviderErrorForCollision(with: try vault.item(for: target))
        }
        if target.hasPrefix(path + "/") {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError)
        }
        if target.lowercased() == path.lowercased() {
            // Case-only: the core's replace goes through a temporary name,
            // since FAT and exFAT see both names as the same entry.
            try vault.call(write: true) { try $0.replace(src: path, dst: target) }
        } else {
            try vault.call(write: true) { try $0.rename(from: path, to: target) }
        }
    }

    override func deleteItem(withIdentifier itemIdentifier: NSFileProviderItemIdentifier, completionHandler: @escaping (Error?) -> Void) {
        do {
            let vault = try activeVault
            let path = try vault.path(for: itemIdentifier)
            guard path != "/" else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
            try vault.removeTree(path)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    // MARK: - Service

    override func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier) throws -> [NSFileProviderServiceSource] {
        guard itemIdentifier == .rootContainer else { return [] }
        return [try activeVault.serviceSource()]
    }
}
