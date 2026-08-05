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
