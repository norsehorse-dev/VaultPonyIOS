import UIKit
import UniformTypeIdentifiers

/// "Save to VaultPony" from the share sheet (2.0.0 rc4, plan 5.1).
///
/// This extension never opens a vault and never links the core. It copies
/// each shared item, file to file, into the app group (`ShareStaging`), then
/// completes the request and opens VaultPony, which imports the files into an
/// unlocked vault. Files are never read whole into memory here: the
/// extension's memory limit is tight and a share can be large.
///
/// Opening the app follows AgePony's share extension: complete the request
/// first, then in its completion handler open the URL through the responder
/// chain, trying `openURL:options:completionHandler:` before the old
/// `openURL:`. If iOS doesn't launch the app, the share stays staged and the
/// app picks it up the next time it comes to the front (within 10 minutes).
final class ShareViewController: UIViewController {
    private static let maxItems = 100
    /// Text shares are capped; anything bigger belongs in a file.
    private static let maxTextBytes = 4 << 20

    private var started = false

    private enum ShareError: Error {
        case nothingToSave
        case prepareFailed
    }

    /// A shared item staged under a temporary name, with the name it should get.
    private struct Staged {
        let tempURL: URL
        let name: String
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()

        let label = UILabel()
        label.text = String(localized: "Preparing…")
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await run() }
    }

    // MARK: - Staging

    @MainActor
    private func run() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = Array(items.flatMap { $0.attachments ?? [] }.prefix(Self.maxItems))
        let token = UUID()
        do {
            let names = try await stage(providers, token: token)
            try ShareStaging.writeManifest(names: names, token: token)
            guard let url = ShareStaging.url(token: token) else { throw ShareError.prepareFailed }
            completeAndOpen(url)
        } catch {
            ShareStaging.remove(token: token)
            let message: String
            if case ShareError.nothingToSave? = error as? ShareError {
                message = String(localized: "Nothing to save.")
            } else {
                message = String(localized: "Couldn't prepare these items.")
            }
            showError(message)
        }
    }

    /// Stages every file, and any text that came without a file as
    /// "Shared text.txt" ("Shared text (1).txt" for a second one). Items that
    /// fail are left out; the share fails only if nothing could be staged.
    /// Returns the staged names in share order.
    private func stage(_ providers: [NSItemProvider], token: UUID) async throws -> [String] {
        var files: [(NSItemProvider, String)] = []
        var texts: [NSItemProvider] = []
        for provider in providers {
            if let type = Self.fileType(of: provider) {
                files.append((provider, type))
            } else if Self.isText(provider) {
                texts.append(provider)
            }
        }
        guard !files.isEmpty || !texts.isEmpty else { throw ShareError.nothingToSave }

        let folder: URL
        do {
            folder = try ShareStaging.makeFilesFolder(token: token)
        } catch {
            throw ShareError.prepareFailed
        }

        var names: [String] = []
        var taken = Set<String>()
        var failures = 0
        func place(_ staged: Staged) {
            let name = ShareStaging.uniqueName(staged.name, taken: taken)
            let dest = folder.appendingPathComponent(name, isDirectory: false)
            do {
                try FileManager.default.moveItem(at: staged.tempURL, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: staged.tempURL)
                failures += 1
                return
            }
            ShareStaging.protect(dest)
            taken.insert(name.lowercased())
            names.append(name)
        }

        for (provider, type) in files {
            do {
                place(try await stageFile(provider, type: type, into: folder))
            } catch {
                failures += 1
            }
        }
        for provider in texts {
            do {
                place(try await stageText(provider, into: folder))
            } catch {
                failures += 1
            }
        }
        guard !names.isEmpty else {
            throw failures > 0 ? ShareError.prepareFailed : ShareError.nothingToSave
        }
        return names
    }

    /// The type to ask for as a file, if the item is one. Text that came
    /// without a file name (a selection, a note) counts as text instead.
    private static func fileType(of provider: NSItemProvider) -> String? {
        let hasFileName = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.suggestedName != nil
        if isText(provider) && !hasFileName { return nil }
        return provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        }
    }

    private static func isText(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
    }

    /// Copies the item's file into `folder` under a temporary name, file to
    /// file. `loadFileRepresentation` deletes its file when the handler
    /// returns, so the copy happens inside the handler.
    private func stageFile(_ provider: NSItemProvider, type: String, into folder: URL) async throws -> Staged {
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareError.prepareFailed)
                    return
                }
                let temp = folder.appendingPathComponent(".incoming-" + UUID().uuidString, isDirectory: false)
                do {
                    try FileManager.default.copyItem(at: url, to: temp)
                    ShareStaging.protect(temp)
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    continuation.resume(throwing: error)
                    return
                }
                // suggestedName can drop the extension; keep the file's own.
                var name = suggested ?? url.lastPathComponent
                let ext = url.pathExtension
                if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() {
                    name += "." + ext
                }
                continuation.resume(returning: Staged(tempURL: temp, name: ShareStaging.safeName(name)))
            }
        }
    }

    private func stageText(_ provider: NSItemProvider, into folder: URL) async throws -> Staged {
        let text = try await loadText(provider)
        let temp = folder.appendingPathComponent(".incoming-" + UUID().uuidString, isDirectory: false)
        try Data(text.utf8).write(to: temp, options: [.completeFileProtection])
        return Staged(tempURL: temp, name: ShareStaging.textFileName)
    }

    private func loadText(_ provider: NSItemProvider) async throws -> String {
        let type = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier : UTType.text.identifier
        let limit = Self.maxTextBytes
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let text = item as? String, text.utf8.count <= limit {
                    continuation.resume(returning: text)
                } else if let attributed = item as? NSAttributedString, attributed.length <= limit {
                    continuation.resume(returning: attributed.string)
                } else if let data = item as? Data, data.count <= limit {
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } else {
                    continuation.resume(throwing: error ?? ShareError.prepareFailed)
                }
            }
        }
    }

    // MARK: - Handing over

    /// Complete first; open the app once the extension's UI is gone. `self`
    /// is captured strongly so the responder chain still resolves then.
    private func completeAndOpen(_ url: URL) {
        guard let context = extensionContext else { return }
        context.completeRequest(returningItems: []) { _ in
            DispatchQueue.main.async {
                self.openThroughResponderChain(url)
            }
        }
    }

    /// Walks the responder chain to the application and asks it to open
    /// `url`. iOS 18 stopped honouring the old `openURL:` selector, so the
    /// current one is tried first.
    @discardableResult
    private func openThroughResponderChain(_ url: URL) -> Bool {
        let modern = sel_registerName("openURL:options:completionHandler:")
        let legacy = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: modern) {
                typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, Any?) -> Void
                let open = unsafeBitCast(current.method(for: modern), to: OpenFn.self)
                open(current, modern, url as NSURL, NSDictionary(), nil)
                return true
            }
            if current.responds(to: legacy) {
                _ = current.perform(legacy, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        })
        present(alert, animated: true)
    }
}
