import Foundation
import Observation

/// Bridges core unlock progress callbacks to @Observable UI state. The
/// core's doc comment warns onProgress "is fired from the unlock thread;
/// implementations must be fast and must not call back into the session" —
/// so this just hops to the main actor and returns immediately.
@Observable
final class UnlockProgress: UnlockProgressListener, @unchecked Sendable {
    var step: UInt32 = 0
    var total: UInt32 = 0
    var prf: String = ""

    func onProgress(step: UInt32, total: UInt32, prf: String) {
        Task { @MainActor in
            self.step = step
            self.total = total
            self.prf = prf
        }
    }
}
