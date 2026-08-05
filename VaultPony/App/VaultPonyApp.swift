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
        .alert("Save Changes?", isPresented: Binding(
            get: { sessionRegistry.pendingWriteBack != nil },
            set: { if !$0 { sessionRegistry.pendingWriteBack = nil } }
        ), presenting: sessionRegistry.pendingWriteBack) { pending in
            Button("Write Back") {
                Task { await sessionRegistry.resolveWriteBack(pending, writeBack: true) }
            }
            Button("Discard", role: .destructive) {
                Task { await sessionRegistry.resolveWriteBack(pending, writeBack: false) }
            }
        } message: { pending in
            Text("\(pending.displayName) was edited on a local copy because its location doesn't support editing in place.")
        }
        .alert("Couldn't Save Changes Back", isPresented: Binding(
            get: { sessionRegistry.lastWriteBackError != nil },
            set: { if !$0 { sessionRegistry.lastWriteBackError = nil } }
        )) {
            Button("OK") { sessionRegistry.lastWriteBackError = nil }
        } message: {
            Text(sessionRegistry.lastWriteBackError ?? "")
        }
    }
}
