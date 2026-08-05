# VaultPonyIOS — Threat Model (iOS-specific deltas)

This document layers the iOS shell's specifics on top of
`VaultPonyCore/THREAT_MODEL.md`, which remains the source of truth for the
core's cryptography, format handling, and general posture. Nothing here
overrides it; this is what changes when the core is embedded in an iOS app.

Status: all sections reviewed as of P7. Each section was verified against
the actual shipped implementation, not just the plan — see the "Reviewed"
line at the end of each section for what was checked and when.

## 1. Opening files (the fd contract on iOS)

`Security/FdOpener.swift` implements PLAN.md section 5 in full: security-
scoped bookmark resolution with stale-bookmark refresh, `ensureDownloaded`
polling `ubiquitousItemDownloadingStatus` and calling
`startDownloadingUbiquitousItem` before any dataless iCloud file is opened
(the core is never handed an fd to a dataless file), `NSFileCoordinator`
wrapping every read and write open (and the write-back replace), and the
copy-in/write-back fallback (`openViaCopyIn` / `writeBack` /
`discardLocalCopy`) for providers that hand back a read-only fd on a
writable open request. Copy-in working files get
`FileProtectionType.complete` and live in a backup-excluded
`Application Support/VaultPony/CopiedVaults` directory. No-trace mode
disables the copy-in fallback outright (`FdOpenError.noTraceCopyInDisabled`)
rather than silently still copying.

Reviewed: P2 (copy-in/write-back landed), re-confirmed P7 — code matches
the plan; device-matrix testing (On My iPhone / iCloud Drive / third-party
provider) is Kevin's on-device checklist item, not something verified from
this session.

## 2. Secrets in Swift memory

Swift `String`/`Data` cannot be reliably zeroized (copy-on-write, bridging),
so the mitigation is minimizing foreign-side lifetime rather than
zeroization. Audited this session (P7):

- `UnlockView`, `CreateContainerView`, and `ChangePasswordView` all clear
  their passphrase/hidden-passphrase/keyfile `@State` back to empty
  immediately after a successful unlock/create/change (and `UnlockView`
  clears them on the biometric-unlock path too, right after adopting the
  session).
- `RecoveryView` did **not** do this for its two restore actions
  (`restoreFromBackupFile` / `restoreFromEmbeddedBackup`) — the entered
  password and keyfiles stayed in `@State` for the rest of the screen's
  lifetime after a successful restore, with no functional need once the
  restore had already verified and applied them. Fixed in P7: both success
  paths now call a `clearSecrets()` that matches the pattern used
  everywhere else in the app.
- `BiometricUnlock.enroll`/`retrieve` hold the passphrase only inside the
  function body around the `SecItemAdd`/`SecItemCopyMatching` call; no
  static/global storage anywhere in `Security/` or `CoreBridge/`.
- Generated UniFFI glue (`Generated/bindings/vault_ffi.swift`) declares no
  top-level mutable state that could retain a passed string — it's pure
  call-stack marshaling into a `RustBuffer` freed when the FFI call
  returns, same shape as the already-reviewed Kotlin bindings on Android.
  The Rust side wraps incoming secrets in `Zeroizing` immediately (core's
  own THREAT_MODEL.md); nothing new to audit there from the iOS side.

Reviewed: P1 (pattern established), P7 (full re-audit across every screen
that touches a passphrase or keyfile; one gap found and fixed — see above).

## 3. Biometric unlock and Keychain

`Security/BiometricUnlock.swift`: per-vault passphrase (not a derived key —
PIM and keyfiles still factor in fresh at unlock time) stored under
`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`.
Enrollment only happens from a successful manual unlock (`UnlockView`,
opt-in checkbox, never auto-enrolled). Wiped on vault removal
(`VaultStore.remove`) and on a wrong-password result via the biometric path
(self-healing against a stale credential after an out-of-band password
change). Re-enrolling biometrics (new face/fingerprint) invalidates the
Keychain item automatically at the OS level; a retrieval failure of any
kind is treated as "no usable credential" rather than trying to distinguish
causes, matching the core's own coarse-error posture.

Reviewed: P5 (implemented and code-reviewed), re-confirmed P7. On-device
verification (Face ID round-trip, re-enrollment invalidation) is Kevin's
checklist item.

## 4. At-rest app data (Recents, prefs, exports, copy-in fallback)

`Storage/VaultStore.swift` and `Storage/AppPrefs.swift` persist only
security-scoped bookmarks and settings — never a passphrase or derived key
— as JSON in Application Support, `FileAttributeKey.protectionKey: .complete`
and `isExcludedFromBackup`, because a bookmark restored to another device is
useless but still leaks a vault's filename. Every transient decrypted-
adjacent file the app creates (`BrowserView` export, `RecoveryView` header-
backup export, `FdOpener`'s copy-in working copies) gets
`FileProtectionType.complete` / `.completeFileProtection` and is deleted as
soon as it's no longer needed (`BrowserView`'s `.onChange(of: showExportSheet)`,
`RecoveryView`'s equivalent, `FdOpener.discardLocalCopy` after write-back).
No decrypted content is ever written to disk outside these explicit,
cleaned-up paths — the viewer holds content in memory only, streamed via
`read_at`.

Reviewed: P2 (write/export paths), P5 (no-trace mode, file-protection
audit), re-confirmed P7.

## 5. Screen and app-switcher exposure

`Security/PrivacyShield.swift` overlays branding over the app-switcher
snapshot on `willResignActive` when a vault is unlocked and the Privacy
Screen setting is on (`RootView` in `VaultPonyApp.swift` gates it on
`scenePhase != .active && sessionRegistry.session != nil &&
appPrefs.privacyScreenEnabled`). iOS has no `FLAG_SECURE` equivalent — this
covers the switcher thumbnail only, not screen recording or a photo of the
screen, and that limitation is documented here and in the Settings footer
text rather than silently accepted or implied away.

Reviewed: P5, re-confirmed P7.

## 6. Zero network

No networking code anywhere in `VaultPony/` (`grep`-verified this session:
no `URLSession`, no `NSAllowsArbitraryLoads` or other ATS override in
`project.yml`, no `Package.swift`/`Podfile` outside the `VaultPonyCore`
submodule). Only outbound "connection" of any kind is
`UIApplication.shared.open(UIApplication.openSettingsURLString)` in
`SettingsView`, which opens the system Settings app locally — not network
traffic. Privacy Nutrition Label declared as "Data Not Collected" (see P7
App Store metadata checklist).

Reviewed: P7.

## 7. App Store / distribution specifics

`ITSAppUsesNonExemptEncryption` was `false` through P0–P6 to keep early
builds simple; corrected to `true` in P7 — the app performs real symmetric
encryption of user file content (AES and friends, via the core), which does
not qualify for Apple's built-in exemptions (those cover things like
HTTPS-only or auth-only use of encryption). With the key set to `true`,
Kevin completes the annual self-classification report / French declaration
process through App Store Connect at each submission — that account-bound
step can't be done from this session. The IDRIX/VeraCrypt trademark notice
already lives in `NOTICE`/`README.md`/`LICENSE` and is repeated in the P7
App Store description copy. Store listing and review-notes framing pitch
VaultPony as a transparent, open-source container utility (source available,
no dark patterns, no "secret vault" marketing) to match Apple's review
guidance against deceptively-marketed vault apps.

Reviewed: P7.

## 8. Standing gates carried over from the core

The core's THREAT_MODEL.md pre-release review gates apply here too. The
generated-glue audit for lingering foreign-side secret copies (section 2
above) now explicitly covers the Swift bindings alongside the Kotlin ones,
and is re-run at every future phase that adds a new screen touching a
passphrase or keyfile, not just at P7.
