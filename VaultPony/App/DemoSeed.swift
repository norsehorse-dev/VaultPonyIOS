#if DEBUG
import Foundation

/// UI-test-only demo data, entirely compiled out of Release builds (the
/// whole file is behind `#if DEBUG`). Fastlane `snapshot` (P7) launches
/// with `-seedDemoVault` so the UI test can navigate straight to a
/// populated vault for App Store screenshots without driving the system
/// file picker, which is one of the flakiest things a UI test can do —
/// the demo container is created directly in the app's own sandbox and
/// added to VaultStore exactly the way a real import would be.
enum DemoSeed {
    static let displayName = "Demo Vault"
    static let passphrase = "DemoPassword123!"

    static func seedIfNeeded(vaultStore: VaultStore) async {
        guard ProcessInfo.processInfo.arguments.contains("-seedDemoVault") else { return }
        guard !vaultStore.vaults.contains(where: { $0.displayName == displayName }) else { return }

        do {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("DemoVault.vc")
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }

            let scheme = Vault.encryptionSchemeOptions().first ?? "AES"
            let prf = Vault.hashOptions().first ?? "SHA-512"
            let filesystem = Vault.filesystemOptions().first ?? "FAT"

            let createFd = Darwin.open(url.path, O_RDWR)
            guard createFd >= 0 else { return }
            try await Vault.createNewContainer(
                fd: createFd,
                size: 8 << 20,
                passphrase: passphrase,
                pim: 0,
                keyfiles: [],
                scheme: scheme,
                prf: prf,
                filesystem: filesystem
            )

            let unlockFd = Darwin.open(url.path, O_RDWR)
            guard unlockFd >= 0 else { return }
            let session = try await Vault.unlock(fd: unlockFd, passphrase: passphrase, pim: 0, keyfiles: [], progress: nil)

            try await Vault.mkdir(session, path: "/Photos")
            try await Vault.create(session, path: "/Welcome.txt")
            let text = Data("Welcome to VaultPony.\n\nThis is a demo file inside an encrypted, VeraCrypt-compatible vault.".utf8)
            try await Vault.writeAt(session, path: "/Welcome.txt", offset: 0, data: text)
            try await Vault.create(session, path: "/Photos/.keep")
            try await Vault.flush(session)
            session.lock()

            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            vaultStore.add(bookmarkData: bookmark, displayName: displayName)
        } catch {
            // Best-effort: a seeding failure just means screenshots show
            // an empty state, never a crash over demo data.
        }
    }
}
#endif
