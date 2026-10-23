import Foundation

/// Share into a vault (2.0.0 rc4, plan 5.1): what the app and its share
/// extension agree on. Compiled into the app, the File Provider extension
/// (as part of Shared/) and the share extension, so it uses Foundation only.
///
/// The share extension never opens a vault and never links the core. It
/// copies what was shared, file to file, into
/// `<group>/Share/<UUID>/files/`, writes `<group>/Share/<UUID>/manifest.json`
/// (the file names, nothing else) last, and opens VaultPony with
/// `vaultpony://share?token=<UUID>`. Everything staged has complete file
/// protection and is excluded from backup. The app moves the folder into its
/// own temporary directory as soon as it sees it, imports from there, and
/// deletes it when the import ends, when the user cancels, and at lock. A
/// folder nobody claimed is picked up on the app's next launch or return to
/// the foreground if it is younger than `maxAge`, and deleted otherwise.
enum ShareStaging {
    /// Same group as `FilesShared.appGroup`; repeated here because the share
    /// extension doesn't compile the rest of Shared/.
    static let appGroup = "group.dev.norsehorse.vaultpony"
    static let urlScheme = "vaultpony"
    static let urlHost = "share"
    static let filesFolder = "files"
    static let manifestName = "manifest.json"
    /// What shared text that came without a file is saved as.
    static let textFileName = "Shared text.txt"
    /// A staged share older than this is deleted instead of picked up.
    static let maxAge: TimeInterval = 600
    /// A file name in the manifest is at most this many UTF-16 units.
    static let maxNameUnits = 200

    struct Manifest: Codable {
        var names: [String]
    }

    /// One staged share waiting in the app group.
    struct Waiting {
        let token: UUID
        let created: Date?
        /// False while the extension is still copying.
        let isComplete: Bool
    }

    static var root: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Share", isDirectory: true)
    }

    static func folder(token: UUID) -> URL? {
        root?.appendingPathComponent(token.uuidString, isDirectory: true)
    }

    // MARK: URL

    static func url(token: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = urlHost
        components.queryItems = [URLQueryItem(name: "token", value: token.uuidString)]
        return components.url
    }

    /// The token of a `vaultpony://share?token=<UUID>` URL. Anything else,
    /// including a token that isn't a UUID, gives nil: the token becomes part
    /// of a path, and any app can open this URL.
    static func token(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == urlScheme,
              url.host?.lowercased() == urlHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "token" })?.value
        else { return nil }
        return UUID(uuidString: value)
    }

    // MARK: Extension side

    /// Creates `<root>/<token>/files/` and returns it.
    static func makeFilesFolder(token: UUID) throws -> URL {
        guard let root, let folder = folder(token: token) else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: attributes)
        excludeFromBackup(root)
        let files = folder.appendingPathComponent(filesFolder, isDirectory: true)
        try manager.createDirectory(at: files, withIntermediateDirectories: true, attributes: attributes)
        excludeFromBackup(folder)
        return files
    }

    /// Written last: a folder with a manifest is complete.
    static func writeManifest(names: [String], token: UUID) throws {
        guard let folder = folder(token: token) else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(Manifest(names: names))
        try data.write(to: folder.appendingPathComponent(manifestName), options: [.atomic, .completeFileProtection])
    }

    static func remove(token: UUID) {
        guard let folder = folder(token: token) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: App side

    /// Every staged share in the app group, complete or not.
    static func waiting() -> [Waiting] {
        guard let root,
              let children = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.creationDateKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }
        return children.compactMap { url in
            guard let token = UUID(uuidString: url.lastPathComponent) else { return nil }
            let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
            let complete = FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestName).path)
            return Waiting(token: token, created: created, isComplete: complete)
        }
    }

    /// The names in a claimed folder's manifest, or nil if it has none.
    static func readManifest(in folder: URL) -> [String]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        return manifest.names
    }

    // MARK: Helpers

    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// A plain file name: the last path component, with path separators and
    /// control characters replaced, no leading dot or space, and at most
    /// `maxNameUnits` long. The app's import then makes it fit the vault's
    /// filesystem. Applying it again changes nothing, which the app relies
    /// on when it checks the manifest.
    static func safeName(_ raw: String) -> String {
        var current = cleanOnce(raw)
        while true {
            let next = cleanOnce(current)
            if next == current { return current }
            current = next
        }
    }

    private static func cleanOnce(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in (raw as NSString).lastPathComponent.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == ":" || scalar == "\\" {
                scalars.append("_")
            } else {
                scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.utf16.count > maxNameUnits {
            let ext = (name as NSString).pathExtension
            let keep = ext.isEmpty || ext.utf16.count > 16 ? "" : "." + ext
            let base = keep.isEmpty ? name : (name as NSString).deletingPathExtension
            name = truncate(base, toUTF16: maxNameUnits - keep.utf16.count) + keep
        }
        return name.isEmpty ? "Shared file" : name
    }

    /// `name`, or "name (1).ext", "name (2).ext" and so on, whichever isn't
    /// in `taken` (compared without regard to case). The result stays a
    /// `safeName`, so the app never drops it as malformed.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let safe = safeName(name)
        guard taken.contains(safe.lowercased()) else { return safe }
        let ext = (safe as NSString).pathExtension
        let dotExt = ext.isEmpty || ext.utf16.count > 16 ? "" : "." + ext
        let base = dotExt.isEmpty ? safe : (safe as NSString).deletingPathExtension
        var n = 1
        while true {
            let suffix = " (\(n))"
            let room = max(maxNameUnits - suffix.utf16.count - dotExt.utf16.count, 1)
            let candidate = safeName(truncate(base, toUTF16: room) + suffix + dotExt)
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// Cuts at a character boundary.
    private static func truncate(_ s: String, toUTF16 limit: Int) -> String {
        guard s.utf16.count > limit else { return s }
        var result = ""
        for ch in s {
            if result.utf16.count + ch.utf16.count > limit { break }
            result.append(ch)
        }
        return result
    }
}
