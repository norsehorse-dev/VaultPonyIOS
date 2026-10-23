import Foundation
import Observation

/// Bridges the core's copy progress ("Convert to VeraCrypt", 2.0.0 rc5) to
/// @Observable UI state. The core fires `onProgress` from the copying thread
/// and asks for it to be fast and never call back into either session, so
/// this only hops to the main actor, as UnlockProgress does.
@Observable
final class ConvertProgress: CopyProgressListener, @unchecked Sendable {
    var filesDone: UInt64 = 0
    var filesTotal: UInt64 = 0
    var bytesDone: UInt64 = 0
    var bytesTotal: UInt64 = 0

    /// The totals from the plan, before the first file is copied.
    @MainActor
    func begin(files: UInt64, bytes: UInt64) {
        filesDone = 0
        filesTotal = files
        bytesDone = 0
        bytesTotal = bytes
    }

    func onProgress(filesDone: UInt64, filesTotal: UInt64, bytesDone: UInt64, bytesTotal: UInt64) {
        Task { @MainActor in
            self.filesDone = filesDone
            self.filesTotal = filesTotal
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
        }
    }
}
