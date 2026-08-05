import SwiftUI

/// P0 walking-skeleton screen: proves the app links against VaultFFI and
/// can call across the UniFFI boundary. Replaced by the real Home /
/// Onboarding flow in P1 (see PLAN.md section 8).
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
            Text("VaultPony")
                .font(.title.bold())
            Text("core_version(): \(coreVersion)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var coreVersion: String {
        core_version()
    }
}

#Preview {
    ContentView()
}
