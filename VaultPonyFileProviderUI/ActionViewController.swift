import FileProvider
import FileProviderUI
import UIKit

/// Shown by Files when the vault isn't unlocked for it any more (the
/// extension answered `notAuthenticated`). There is no password entry here
/// on purpose: unlocking happens in VaultPony, where Argon2id, keyfiles and
/// hidden volumes are handled. This screen only says so.
final class ActionViewController: FPUIActionExtensionViewController {
    override func prepare(forError error: Error) {
        let title = UILabel()
        title.text = String(localized: "Open VaultPony to unlock this vault.")
        title.font = .preferredFont(forTextStyle: .headline)
        title.numberOfLines = 0
        title.textAlignment = .center

        let detail = UILabel()
        detail.text = String(localized: "Turn on Show in Files when you unlock it.")
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center

        let done = UIButton(type: .system, primaryAction: UIAction(title: String(localized: "Done")) { [weak self] _ in
            self?.extensionContext.cancelRequest(withError: NSError(
                domain: FPUIErrorDomain,
                code: Int(FPUIExtensionErrorCode.userCancelled.rawValue)
            ))
        })

        let stack = UIStackView(arrangedSubviews: [title, detail, done])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
        extensionContext.cancelRequest(withError: NSError(
            domain: FPUIErrorDomain,
            code: Int(FPUIExtensionErrorCode.userCancelled.rawValue)
        ))
    }
}
