import Foundation

enum FilesXPCInterface {
    /// The interface for `VaultFilesXPC`, with `FileHandle` allowed as the
    /// container argument (it carries the fd across).
    static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: VaultFilesXPC.self)
        interface.setClasses(
            NSSet(object: FileHandle.self) as! Set<AnyHashable>,
            for: #selector(VaultFilesXPC.adopt(_:container:idKey:policy:token:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        return interface
    }
}
