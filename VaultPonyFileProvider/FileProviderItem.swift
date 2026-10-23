import FileProvider
import UniformTypeIdentifiers

/// A vault file or folder as Files sees it. No tags, favorites, last-used
/// dates or thumbnails (D20): nothing that would put vault content into
/// Recents or the system's indexes.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let isDirectory: Bool

    init(path: String, entry: DirEntry, codec: ItemIDCodec, writable: Bool) {
        itemIdentifier = codec.identifier(for: path)
        parentItemIdentifier = codec.identifier(for: VaultPath.parent(path))
        filename = entry.name
        isDirectory = entry.isDir
        if entry.isDir {
            contentType = .folder
            documentSize = nil
            capabilities = writable
                ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting, .allowsDeleting]
                : [.allowsReading, .allowsContentEnumerating]
        } else {
            let ext = (entry.name as NSString).pathExtension
            contentType = UTType(filenameExtension: ext) ?? .data
            documentSize = NSNumber(value: entry.size)
            capabilities = writable
                ? [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
                : [.allowsReading]
        }
        contentModificationDate = entry.mtimeMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        super.init()
    }

    private init(rootWritable writable: Bool) {
        itemIdentifier = .rootContainer
        parentItemIdentifier = .rootContainer
        filename = FilesShared.domainDisplayName
        contentType = .folder
        documentSize = nil
        contentModificationDate = nil
        isDirectory = true
        capabilities = writable
            ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
            : [.allowsReading, .allowsContentEnumerating]
        super.init()
    }

    static func root(writable: Bool) -> FileProviderItem {
        FileProviderItem(rootWritable: writable)
    }
}
