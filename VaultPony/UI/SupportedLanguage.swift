import SwiftUI

/// A language VaultPony ships a String Catalog translation for — must
/// match `CFBundleLocalizations` in project.yml. Shared between
/// SettingsView's language picker and OnboardingView's Language slide,
/// both of which offer the same live, in-app switcher (parity port of
/// VaultPonyAndroid's `SupportedLanguage`/`LocaleManager`). Native names
/// are shown as-is, never routed through the string catalog — a language
/// always names itself in itself, the same way Android's `nativeName`
/// does.
struct SupportedLanguage: Identifiable {
    let code: String
    let nativeName: String
    var id: String { code }

    static let all: [SupportedLanguage] = [
        SupportedLanguage(code: "en", nativeName: "English"),
        SupportedLanguage(code: "de", nativeName: "Deutsch"),
        SupportedLanguage(code: "es", nativeName: "Español"),
        SupportedLanguage(code: "fr", nativeName: "Français"),
        SupportedLanguage(code: "ru", nativeName: "Русский"),
        SupportedLanguage(code: "pt-BR", nativeName: "Português (Brasil)"),
    ]
}

/// One row in the live language picker — shared by SettingsView and
/// OnboardingView so both switchers look and behave identically. A name
/// plus a checkmark when it's the active selection. `title` is passed in
/// as `Text` rather than a raw string so callers control whether it's
/// catalog-localized ("System") or a native language name shown as-is.
struct LanguageOptionRow: View {
    let title: Text
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                title
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
