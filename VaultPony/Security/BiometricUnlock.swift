import Foundation
import LocalAuthentication
import Security

/// Per-vault biometric unlock (PLAN.md sections 6 and 7). Stores the raw
/// passphrase — not a derived key; PIM and keyfiles, if the vault uses
/// them, still factor in fresh at unlock time exactly as a manual unlock
/// would — in a Keychain item gated by
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`.
/// Re-enrolling biometrics (adding/removing a face or fingerprint)
/// invalidates the item automatically at the OS level; VaultPony treats
/// any retrieval failure as "no usable stored credential" rather than
/// trying to distinguish causes, matching the core's own coarse-error
/// posture.
enum BiometricUnlock {
    private static let service = "dev.norsehorse.vaultpony.biometric"

    enum BiometricError: LocalizedError {
        case unavailable
        case storeFailed(OSStatus)
        case notEnrolled

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Face ID or Touch ID isn't available on this device."
            case .storeFailed:
                return "Couldn't save the passphrase for biometric unlock."
            case .notEnrolled:
                return "This vault isn't enrolled for biometric unlock."
            }
        }
    }

    /// Whether the device currently supports Face ID/Touch ID and has it
    /// enrolled — checked before showing the opt-in toggle.
    static func isAvailable() -> Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Opts a vault in: stores its passphrase behind biometry. Overwrites
    /// any existing stored credential for this vault.
    static func enroll(vaultId: UUID, passphrase: String) throws {
        guard isAvailable() else { throw BiometricError.unavailable }
        guard let data = passphrase.data(using: .utf8) else { throw BiometricError.storeFailed(errSecParam) }

        remove(vaultId: vaultId)

        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            throw BiometricError.storeFailed(errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultId.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricError.storeFailed(status)
        }
    }

    /// Retrieves the stored passphrase, prompting Face ID/Touch ID.
    /// Throws rather than returning a stale/invalidated credential if
    /// nothing is enrolled, the OS invalidated the item (biometry
    /// re-enrollment), or the user cancels/fails the prompt.
    static func retrieve(vaultId: UUID, reason: String) async throws -> String {
        let context = LAContext()
        context.localizedReason = reason

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultId.uuidString,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]

        return try await Task.detached {
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data, let passphrase = String(data: data, encoding: .utf8) else {
                throw BiometricError.notEnrolled
            }
            return passphrase
        }.value
    }

    /// Whether a credential is currently stored for this vault, without
    /// triggering a biometric prompt — a lightweight existence check the
    /// UI uses to decide whether to show "Unlock with Face ID".
    static func isEnrolled(vaultId: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultId.uuidString,
            kSecReturnData as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed means the item exists but needs
        // biometric auth to read — that still counts as "enrolled" here.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Wipes the stored credential — called when the vault is removed
    /// from Recents, the user opts out, or an enrolled unlock fails with
    /// wrong-password (a biometric credential must never persist past a
    /// password it no longer matches).
    @discardableResult
    static func remove(vaultId: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultId.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
