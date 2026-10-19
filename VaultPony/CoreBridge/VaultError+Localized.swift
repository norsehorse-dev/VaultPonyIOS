import Foundation

/// User-facing text for the core's deliberately-coarse error contract
/// (vault-ffi/src/lib.rs doc comment, THREAT_MODEL-IOS.md section 2):
/// shells branch on these, they don't diagnose. Mirrors the Rust
/// #[error(...)] strings so iOS and Android show the same story.
///
/// UniFFI's generated bindings already declare
/// `extension VaultError: LocalizedError` themselves (using the raw case
/// name via String(reflecting:)) — this is a separate property, not
/// another LocalizedError conformance, so it doesn't collide with that.
extension VaultError {
    var message: String {
        let locale = LanguageOverride.locale
        switch self {
        case .NotFoundOrWrongPassword:
            return String(localized: "Wrong password/PIM, or not a VeraCrypt container.", locale: locale)
        case .VersionTooNew:
            return String(localized: "This container requires a newer format version than VaultPony supports.", locale: locale)
        case .SystemVolume:
            return String(localized: "System-encryption volumes are not supported.", locale: locale)
        case .HiddenVolumeProtected:
            return String(localized: "Write blocked to protect the hidden volume; the volume is now read-only.", locale: locale)
        case .HeaderDamaged:
            return String(localized: "The volume header is damaged. The embedded backup header may help — see Recovery.", locale: locale)
        case .UnsupportedFilesystem(let name):
            return String(localized: "Filesystem not supported yet: \(name).", locale: locale)
        case .Filesystem(let detail):
            return String(localized: "Filesystem error: \(detail)", locale: locale)
        case .Io(let detail):
            return String(localized: "I/O error: \(detail)", locale: locale)
        case .Internal:
            return String(localized: "Something went wrong internally. Try again.", locale: locale)
        case .KdfOutOfMemory(let neededMib):
            return String(localized: "Not enough free memory for Argon2id (\(Int(neededMib)) MB needed). Close other apps and try again, or choose PBKDF2 if this vault doesn't use Argon2id.", locale: locale)
        case .Cancelled:
            return String(localized: "Unlock cancelled.", locale: locale)
        case .PasswordTooShortForPim(let minLen, let defaultPim):
            return String(localized: "A PIM below \(Int(defaultPim)) needs a password of at least \(Int(minLen)) characters.", locale: locale)
        }
    }
}
