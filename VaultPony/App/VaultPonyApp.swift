import SwiftUI
import UIKit

@main
struct VaultPonyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vaultStore = VaultStore.shared
    @State private var sessionRegistry = SessionRegistry.shared
    @State private var appPrefs = AppPrefs.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(vaultStore)
                .environment(sessionRegistry)
                .environment(appPrefs)
                .environment(ShareInbox.shared)
                .environment(\.locale, appPrefs.locale)
        }
    }
}

private struct RootView: View {
    @Environment(VaultStore.self) private var vaultStore
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(AppPrefs.self) private var appPrefs
    @Environment(ShareInbox.self) private var shareInbox
    @Environment(\.scenePhase) private var scenePhase

    /// A claimed share asks where to go once onboarding is done, no copy is
    /// running, and the user isn't on their way to unlock a vault for it.
    private var showsShare: Bool {
        shareInbox.pending != nil
            && appPrefs.onboardingDone
            && !appPrefs.replayOnboardingRequested
            && sessionRegistry.activeTransfer == nil
            && sessionRegistry.activeConvert == nil
            && (sessionRegistry.session != nil || !shareInbox.awaitingUnlock)
    }

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
            shareInbox.pickUp()
        }
        // From the share extension (2.0.0 rc4). Only a UUID token is
        // accepted; the staged folder moves into the app at once. A URL
        // that arrives before the app is active (returning from the share
        // sheet) waits: the auto-lock that may run on becoming active would
        // delete a share claimed now. The pick-up after
        // sceneDidBecomeActive claims it instead.
        .onOpenURL { url in
            if scenePhase == .active {
                shareInbox.handle(url)
            }
        }
        .sheet(isPresented: Binding(
            get: { showsShare },
            set: { isShown in
                // Swiped away: cancelled. Not when the sheet closed because
                // the user went to unlock a vault or the import started.
                if !isShown, !shareInbox.awaitingUnlock, shareInbox.pending != nil {
                    shareInbox.discard()
                }
            }
        )) {
            if let share = shareInbox.pending {
                ShareImportView(share: share)
                    .environment(vaultStore)
                    .environment(sessionRegistry)
                    .environment(appPrefs)
                    .environment(shareInbox)
                    .environment(\.locale, appPrefs.locale)
                    .privacyShielded()
            }
        }
        // "Convert to VeraCrypt" (2.0.0 rc5) covers the app, so a lock that
        // leaves the vault's screens still shows how the copy ended.
        .fullScreenCover(isPresented: Binding(
            get: { sessionRegistry.activeConvert != nil },
            set: { if !$0 { sessionRegistry.endConvert() } }
        )) {
            if let job = sessionRegistry.activeConvert {
                ConvertView(job: job)
                    .environment(vaultStore)
                    .environment(sessionRegistry)
                    .environment(appPrefs)
                    .environment(\.locale, appPrefs.locale)
                    .privacyShielded()
            }
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
                sessionRegistry.activeConvert?.appDidEnterBackground()
                sessionRegistry.sceneDidEnterBackground()
            case .active:
                // Any lock that came due while away happens before a
                // paused copy decides whether to resume.
                sessionRegistry.sceneDidBecomeActive()
                sessionRegistry.activeTransfer?.appDidBecomeActive()
                sessionRegistry.activeConvert?.appDidBecomeActive()
                // A share the extension couldn't hand over (2.0.0 rc4).
                shareInbox.pickUp()
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
        .alert("Files Access", isPresented: Binding(
            get: { sessionRegistry.filesError != nil },
            set: { if !$0 { sessionRegistry.filesError = nil } }
        )) {
            Button("OK") { sessionRegistry.filesError = nil }
        } message: {
            Text(verbatim: sessionRegistry.filesError ?? "")
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
        // Nothing is unlocked at launch, so any Files domain is a leftover.
        Task { await FilesBridge.shared.sweep() }
        // A share claimed by a run that ended before importing it.
        ShareInbox.shared.removeAllClaimed()
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
