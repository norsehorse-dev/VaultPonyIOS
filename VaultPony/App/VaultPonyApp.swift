import SwiftUI

@main
struct VaultPonyApp: App {
    @State private var vaultStore = VaultStore()
    @State private var sessionRegistry = SessionRegistry()
    @State private var appPrefs = AppPrefs()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(vaultStore)
                .environment(sessionRegistry)
                .environment(appPrefs)
                .environment(\.locale, appPrefs.locale)
        }
    }
}

private struct RootView: View {
    @Environment(VaultStore.self) private var vaultStore
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(AppPrefs.self) private var appPrefs
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if appPrefs.onboardingDone && !appPrefs.replayOnboardingRequested {
                HomeView()
            } else {
                OnboardingView {
                    appPrefs.setOnboardingDone(true)
                    appPrefs.clearReplayOnboardingRequest()
                }
            }
            if scenePhase != .active && sessionRegistry.session != nil && appPrefs.privacyScreenEnabled {
                PrivacyShield()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            sessionRegistry.autoLockSeconds = appPrefs.autoLockSeconds
        }
        #if DEBUG
        .task {
            await DemoSeed.seedIfNeeded(vaultStore: vaultStore)
        }
        #endif
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
