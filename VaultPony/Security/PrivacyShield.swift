import SwiftUI

/// Overlays the app-switcher snapshot with branding instead of vault
/// content when the scene resigns active. THREAT_MODEL-IOS.md section 5:
/// iOS has no FLAG_SECURE equivalent — this hides the switcher thumbnail
/// only, not screen recording or a photo of the screen.
struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                Text("VaultPony")
                    .font(.title2.bold())
            }
        }
    }
}

/// The same shield for sheets and full-screen covers (2.0.0 rc5): the root
/// view's overlay sits under anything presented on top of it, so a sheet's
/// folder names, the camera preview or the convert screen would otherwise
/// show in the app switcher. Needs `AppPrefs` and `SessionRegistry` in the
/// environment, as every presented vault screen already has.
private struct PrivacyShieldModifier: ViewModifier {
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(AppPrefs.self) private var appPrefs
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if scenePhase != .active && sessionRegistry.session != nil && appPrefs.privacyScreenEnabled {
                PrivacyShield()
                    .transition(.opacity)
            }
        }
    }
}

extension View {
    /// Covers this presented screen in the app switcher, like the root view.
    func privacyShielded() -> some View {
        modifier(PrivacyShieldModifier())
    }
}
