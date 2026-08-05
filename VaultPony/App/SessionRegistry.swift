import Foundation
import Observation

/// Tracks the one currently-unlocked session (P1: single-session UX —
/// Unlock, browse, lock). Auto-locks after autoLockSeconds of inactivity;
/// VaultPonyApp also calls lock()/flush() on scene-background transitions
/// (PLAN.md section 6, 8).
@Observable
final class SessionRegistry {
    private(set) var session: VaultSession?
    private(set) var vaultId: UUID?
    private(set) var facts: VolumeFacts?

    var autoLockSeconds: TimeInterval = 300
    private var lockTask: Task<Void, Never>?

    func adopt(_ session: VaultSession, vaultId: UUID, facts: VolumeFacts) {
        self.session = session
        self.vaultId = vaultId
        self.facts = facts
        resetAutoLockTimer()
    }

    func markActivity() {
        guard session != nil else { return }
        resetAutoLockTimer()
    }

    /// Best-effort flush; write path lands in P2, this is a harmless
    /// no-op on the read-only P1 flows that call it defensively on
    /// backgrounding.
    func flush() {
        try? session?.flush()
    }

    func lock() {
        lockTask?.cancel()
        lockTask = nil
        session?.lock()
        session = nil
        vaultId = nil
        facts = nil
    }

    private func resetAutoLockTimer() {
        lockTask?.cancel()
        let seconds = autoLockSeconds
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.lock() }
        }
    }
}
