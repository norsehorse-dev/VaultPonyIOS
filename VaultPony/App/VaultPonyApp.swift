import SwiftUI
import UIKit

@main
struct VaultPonyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vaultStore = VaultStore()
    @State private var sessionRegistry = SessionRegistry.shared
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
            if let transfer = sessionRegistry.activeTransfer {
                TransferProgressOverlay(transfer: transfer)
                    .zIndex(0.5)
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
        .onChange(of: appPrefs.languageCode) { _, _ in
            sessionRegistry.refreshQuickAction()
        }
        #if DEBUG
        .task {
            await DemoSeed.seedIfNeeded(vaultStore: vaultStore)
        }
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // A copy in progress goes first so it can hold off the
                // auto-lock until its current file is written.
                sessionRegistry.activeTransfer?.appDidEnterBackground()
                sessionRegistry.sceneDidEnterBackground()
            case .active:
                // Any lock that came due while away happens before a
                // paused copy decides whether to resume.
                sessionRegistry.sceneDidBecomeActive()
                sessionRegistry.activeTransfer?.appDidBecomeActive()
            default:
                break
            }
        }
        .alert(Text(verbatim: sessionRegistry.transferSummary?.title ?? ""), isPresented: Binding(
            get: { sessionRegistry.transferSummary != nil },
            set: { if !$0 { sessionRegistry.transferSummary = nil } }
        ), presenting: sessionRegistry.transferSummary) { _ in
            Button("OK") { sessionRegistry.transferSummary = nil }
        } message: { summary in
            if !summary.message.isEmpty {
                Text(verbatim: summary.message)
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

// MARK: - Home Screen quick action

/// "Lock vaults" on the app icon's Home Screen menu (2.0.0). A dynamic
/// item, so it shows only while a vault is unlocked: SessionRegistry adds
/// it when a session is adopted and removes it on lock. It never names a
/// vault.
@MainActor
enum QuickActions {
    static let lockVaultsType = "dev.norsehorse.vaultpony.lock-vaults"

    static func sync(unlocked: Bool) {
        let application = UIApplication.shared
        guard unlocked else {
            if application.shortcutItems?.isEmpty == false {
                application.shortcutItems = []
            }
            return
        }
        application.shortcutItems = [
            UIApplicationShortcutItem(
                type: lockVaultsType,
                localizedTitle: String(localized: "Lock vaults", locale: LanguageOverride.locale),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "lock.fill"),
                userInfo: nil
            ),
        ]
    }

    /// Returns false for an item that isn't ours.
    static func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == lockVaultsType else { return false }
        SessionRegistry.shared.lockAll()
        return true
    }
}

/// Gives SwiftUI's window scenes a delegate that receives the quick
/// action, and clears a "Lock vaults" item left over from a run that ended
/// with a vault unlocked (dynamic items outlive the process).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        QuickActions.sync(unlocked: false)
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// SwiftUI still owns the window; this only picks up the quick action.
/// A tap while the app is running (or suspended) arrives in
/// `windowScene(_:performActionFor:completionHandler:)`; one that launches
/// the app, or reconnects a scene the system discarded, arrives in the
/// connection options.
@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let item = connectionOptions.shortcutItem {
            _ = QuickActions.perform(item)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(QuickActions.perform(shortcutItem))
    }
}
