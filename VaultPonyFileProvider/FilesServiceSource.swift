import FileProvider
import Foundation

/// The app's line into the extension. Restricted to VaultPony itself, and
/// every call must present the per-share token from the app group.
final class FilesServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, VaultFilesXPC {
    let serviceName = FilesShared.serviceName
    /// Only the app that owns this extension may connect. Set explicitly
    /// rather than relying on the default.
    let isRestricted = true

    private unowned let vault: FilesVault
    private var listeners: [NSXPCListener] = []
    private let listenersLock = NSLock()

    init(vault: FilesVault) {
        self.vault = vault
        super.init()
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        let listener = NSXPCListener.anonymous()
        listener.delegate = self
        listenersLock.lock()
        listeners.append(listener)
        listenersLock.unlock()
        listener.resume()
        return listener.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = FilesXPCInterface.make()
        connection.exportedObject = self
        // Without resume() the app sees a misleading sandbox error.
        connection.resume()
        return true
    }

    // MARK: VaultFilesXPC

    func adopt(_ blob: Data, container: FileHandle, idKey: Data, policy: Data, token: Data, reply: @escaping (NSError?) -> Void) {
        defer { try? container.close() }
        guard FilesToken.matches(token) else {
            reply(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
            return
        }
        do {
            try vault.adopt(blob: blob, container: container, idKey: idKey, policyData: policy)
            vault.signal(.rootContainer)
            reply(nil)
        } catch {
            reply(error as NSError)
        }
    }

    func lock(token: Data, reply: @escaping () -> Void) {
        if FilesToken.matches(token) {
            vault.lockNow()
        }
        reply()
    }

    func status(token: Data, reply: @escaping (Bool) -> Void) {
        reply(FilesToken.matches(token) && vault.isOpen)
    }
}
