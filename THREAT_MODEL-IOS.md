# VaultPonyIOS — Threat Model (iOS-specific deltas)

This document layers the iOS shell's specifics on top of
`VaultPonyCore/THREAT_MODEL.md`, which remains the source of truth for the
core's cryptography, format handling, and general posture. Nothing here
overrides it; this is what changes when the core is embedded in an iOS app.

Status: skeleton, opened at P0. Each section below gets filled in and
reviewed at the phase gate that introduces the behavior it covers (see
PLAN.md section 8). Until a section has a "Reviewed: P<n>" line, treat it as
provisional.

## 1. Opening files (the fd contract on iOS)

Provisional — see PLAN.md section 5. Covers: security-scoped bookmarks,
dataless iCloud files, third-party file-provider open-in-place failures and
the copy-in/copy-back fallback, NSFileCoordinator around provider writes,
flush-on-background.

Reviewed: not yet (target: P1 gate)

## 2. Secrets in Swift memory

Provisional — see PLAN.md section 7. Swift String/Data cannot be reliably
zeroized; mitigation is minimizing foreign-side lifetime and auditing
generated UniFFI glue for lingering copies (extends the core's existing
audit gate to the Swift bindings).

Reviewed: not yet (target: P1 gate, re-checked at P7)

## 3. Biometric unlock and Keychain

Provisional — see PLAN.md section 7. Per-vault passphrase in a
biometry-gated Keychain item (kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
+ biometryCurrentSet), opt-in, off by default, invalidated on biometry
re-enrollment and on wrong-password failures.

Reviewed: not yet (target: P5 gate)

## 4. At-rest app data (Recents, prefs, exports, copy-in fallback)

Provisional — see PLAN.md section 7. No decrypted content persists outside
memory except explicit exports and the copy-in fallback, both
NSFileProtectionComplete and backup-excluded. Recents/prefs hold bookmarks
and settings only, no secrets, still protected and backup-excluded because a
bookmark leaks a filename.

Reviewed: not yet (target: P2 gate for write/export paths, P5 for no-trace)

## 5. Screen and app-switcher exposure

Provisional — see PLAN.md section 7. iOS has no FLAG_SECURE equivalent; the
mitigation (PrivacyShield overlay on willResignActive) hides the
app-switcher snapshot but cannot block screen recording or a physical photo.
Documented as a platform limitation, not silently accepted.

Reviewed: not yet (target: P5 gate)

## 6. Zero network

No networking code, no analytics, no third-party SDKs. Verified by: no
NSAllowsArbitraryLoads, no network entitlements, dependency list stays empty
(PLAN.md section 1), Privacy Nutrition Label declares "Data Not Collected."

Reviewed: not yet (target: P7 gate, re-checked before every release)

## 7. App Store / distribution specifics

Export compliance (ITSAppUsesNonExemptEncryption, French declaration, annual
self-classification), IDRIX/VeraCrypt trademark notice in-app and in the
store listing, review-guideline framing as a transparent open-source utility
rather than a "secret" app.

Reviewed: not yet (target: P7 gate)

## 8. Standing gates carried over from the core

The core's THREAT_MODEL.md pre-release review gates apply here too,
specifically the generated-glue audit for lingering foreign-side secret
copies — now covering the Swift bindings alongside the Kotlin ones.
