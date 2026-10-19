import SwiftUI

private enum OnboardingSlideKind {
    case plain
    case language
    case create
}

private struct OnboardingSlide {
    let icon: String
    let title: String
    let body: String
    let kind: OnboardingSlideKind
}

/// Port of VaultPonyAndroid's OnboardingScreen slide list. The Language
/// slide offers the same live, in-app switcher as SettingsView's
/// "Language" section (see OnboardingLanguagePage/LanguageOptionRow in
/// SupportedLanguage.swift) — tapping a language applies it immediately
/// via AppPrefs/`\.locale`, no restart or leaving the screen. The
/// Security slide's copy uses iOS's actual feature names (Face ID,
/// Privacy Screen) in place of Android's generic "biometric"/"secure
/// screen" wording.
private let onboardingSlides: [OnboardingSlide] = [
    OnboardingSlide(icon: "globe", title: "Language", body: "Choose your language. You can change it anytime in Settings.", kind: .language),
    OnboardingSlide(icon: "lock.fill", title: "VaultPony", body: "Encrypted vaults you control. Open source, and compatible with VeraCrypt.", kind: .plain),
    OnboardingSlide(icon: "lock.badge.plus", title: "Create your first vault", body: "A vault is a single encrypted file. Put anything inside; only your password opens it.", kind: .create),
    OnboardingSlide(icon: "eye.slash", title: "Hidden Volumes", body: "Hide a second vault inside the first. Type its password on its own to open it. The outer password gives no sign it exists.", kind: .plain),
    OnboardingSlide(icon: "faceid", title: "Locked Down", body: "Face ID unlock, auto-lock when you leave, and a Privacy Screen keep your vaults yours.", kind: .plain),
]

/// Index of the "Create your first vault" slide — used to resume the
/// carousel just past it once the onboarding create-vault sheet finishes,
/// mirroring Android's `ONBOARDING_CREATE_SLIDE` resume behavior.
private let onboardingCreateSlideIndex = 2

/// First-run onboarding carousel (parity port of VaultPonyAndroid's
/// OnboardingScreen). `onFinish` is called when the user skips or reaches
/// the end of the carousel; the caller (VaultPonyApp's RootView) is
/// responsible for persisting completion via AppPrefs.
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var currentPage: Int
    @State private var showCreateVault = false

    init(startPage: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _currentPage = State(initialValue: min(max(startPage, 0), onboardingSlides.count - 1))
    }

    private var isLastPage: Bool { currentPage == onboardingSlides.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLastPage {
                    Button("Skip") {
                        onFinish()
                    }
                    .padding()
                    .accessibilityIdentifier("onboardingSkipButton")
                } else {
                    Color.clear.frame(width: 1, height: 44)
                }
            }

            TabView(selection: $currentPage) {
                ForEach(Array(onboardingSlides.enumerated()), id: \.offset) { index, slide in
                    OnboardingPageView(slide: slide) {
                        showCreateVault = true
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack {
                HStack(spacing: 8) {
                    ForEach(onboardingSlides.indices, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: index == currentPage ? 10 : 8, height: index == currentPage ? 10 : 8)
                    }
                }
                Spacer()
                Button(isLastPage ? "Get Started" : "Next") {
                    if isLastPage {
                        onFinish()
                    } else {
                        withAnimation { currentPage += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(isLastPage ? "onboardingGetStartedButton" : "onboardingNextButton")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .sheet(isPresented: $showCreateVault) {
            OnboardingCreateVaultFlow {
                showCreateVault = false
                withAnimation {
                    currentPage = min(onboardingCreateSlideIndex + 1, onboardingSlides.count - 1)
                }
            }
        }
    }
}

private struct OnboardingPageView: View {
    let slide: OnboardingSlide
    let onCreateVault: () -> Void

    var body: some View {
        switch slide.kind {
        case .language:
            // Built on a real List instead of the shared ScrollView+VStack
            // layout below — a plain VStack of Buttons has no row
            // separators, backgrounds, or standard row height, so the
            // language options read as bare text links. A List gives
            // genuine native list chrome (matches iOS's own Settings >
            // Language & Region picker) for free.
            OnboardingLanguagePage(slide: slide)
        case .plain, .create:
            ScrollView {
                VStack(spacing: 12) {
                    Spacer(minLength: 40)
                    Image(systemName: slide.icon)
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
                    Text(LocalizedStringKey(slide.title))
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text(LocalizedStringKey(slide.body))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)

                    if slide.kind == .create {
                        Button("Create a Vault") {
                            onCreateVault()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 32)
                .frame(minHeight: 400)
            }
        }
    }
}

/// The Language slide's page content: an icon/title/body header (styled
/// to sit flush with the list, no row chrome of its own) followed by a
/// grouped, inset-style List of languages — reuses the same
/// LanguageOptionRow as SettingsView's Language section so both live
/// switchers look and behave identically.
private struct OnboardingLanguagePage: View {
    let slide: OnboardingSlide
    @Environment(AppPrefs.self) private var appPrefs

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: slide.icon)
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
                    Text(LocalizedStringKey(slide.title))
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text(LocalizedStringKey(slide.body))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(SupportedLanguage.all) { language in
                    LanguageOptionRow(title: Text(language.nativeName), isSelected: appPrefs.languageCode == language.code) {
                        appPrefs.setLanguageCode(language.code)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
    }
}

/// Self-contained NavigationStack presented as a sheet from the onboarding
/// Create-vault slide, reusing CreateContainerView/VaultCreatedView exactly
/// as HomeView does — with a custom `onDone` that dismisses the sheet and
/// resumes the carousel instead of resetting a Home-owned NavigationPath.
private struct OnboardingCreateVaultFlow: View {
    let onDone: () -> Void
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            CreateContainerView(path: $path)
                .navigationDestination(for: CreatedVaultSummary.self) { summary in
                    VaultCreatedView(summary: summary, path: $path, onDone: onDone)
                }
        }
    }
}
