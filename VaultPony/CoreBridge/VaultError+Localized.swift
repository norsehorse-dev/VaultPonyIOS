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
        switch self {
        case .NotFoundOrWrongPassword:
            return "Wrong password/PIM, or not a VeraCrypt container."
        case .VersionTooNew:
            return "This container requires a newer format version than VaultPony supports."
        case .SystemVolume:
            return "System-encryption volumes are not supported."
        case .HiddenVolumeProtected:
            return "Write blocked to protect the hidden volume; the volume is now read-only."
        case .HeaderDamaged:
            return "The volume header is damaged. The embedded backup header may help — see Recovery."
        case .UnsupportedFilesystem(let name):
            return "Filesystem not supported yet: \(name)."
        case .Filesystem(let detail):
            return "Filesystem error: \(detail)"
        case .Io(let detail):
            return "I/O error: \(detail)"
        case .Internal:
            return "Something went wrong internally. Try again."
        }
    }
}
