import SwiftUI

@main
struct VaultPonyApp: App {
    @State private var vaultStore = VaultStore()
    @State private var sessionRegistry = SessionRegistry()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(vaultStore)
                .environment(sessionRegistry)
        }
    }
}

private struct RootView: View {
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            HomeView()
            if scenePhase != .active && sessionRegistry.session != nil {
                PrivacyShield()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                sessionRegistry.flush()
            }
        }
    }
}
