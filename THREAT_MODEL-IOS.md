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
provider) is an on-device checklist item, not something verifiable in code
review.

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

Auto-lock (2.0.0): the delay counts from when the app goes to the
background or the screen turns off, and the deadline is checked again on
return because a suspended app runs no timers. "Immediately" locks on the
background transition itself. Any longer delay means the unlocked
session, and so the volume's master key in the core, stays in process
memory while VaultPony is in the background; the Settings footer says so.
The default is "Immediately" and there is no "Never". The background time
is recorded even with nothing unlocked, so an unlock that completes after
the user has left still locks on schedule. A bulk import or export holds
the lock off only until its current file is written and flushed, then
lets it happen; if the copy runs out of background time mid-file, the
vault locks at once. Imports write each file under a temporary
".vaultpony-*.part" name and rename it into place when complete.

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
verification (Face ID round-trip, re-enrollment invalidation) is an
on-device checklist item.

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

Folder export (2.0.0) writes decrypted files into a folder the user picks
in Files. That is the point of the action, so those files get no special
protection or cleanup; in no-trace mode it asks first, like single-file
export.

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
The annual self-classification report / French declaration is completed
through App Store Connect at each submission — an account-bound step. The IDRIX/VeraCrypt trademark notice
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

## 9. Files access: the File Provider extension (2.0.0 rc3)

"Show in Files" on the unlock screen (off by default, per unlock, hidden in
no-trace mode) puts the unlocked vault into the Files app through a
non-replicated File Provider extension (`VaultPonyFileProvider`). The
research behind the design is in the Android repo's
`VaultPony_2.0.0_rc3_Spike.md`; the decisions are plan D18 to D20.

What changes:

- **A second process holds the keys.** The extension is held to about 20 MB
  and can't run Argon2id, so the app unlocks and hands it the core's key
  handoff blob (master keys, geometry, a container fingerprint; never the
  password, PIM or keyfiles) plus a dup of the container fd, over the File
  Provider XPC service. The service sets `isRestricted`, so only VaultPony
  can connect, and every call must also present a random token the app
  writes to the app group for each share. Keys stay in the two processes'
  memory; nothing goes to the Keychain. Only an unlock with "Show in Files"
  keeps the extra key copy the handoff needs. The core's THREAT_MODEL.md
  argues the handoff, including the copies the FFI glue, Swift `Data` and
  XPC keep and nobody can wipe.
- **Decrypted files on disk.** A file opened from Files is written out in
  full to the domain's folder inside the app group, with
  `FileProtectionType.complete` (folders too) and excluded from backup, and
  deleted when no app uses it any more (`stopProvidingItem`) and at lock.
  This is new: until now plaintext only reached disk on an explicit export.
  The setting's footer says so.
- **Saves from other apps.** An app that edits a file opened from Files
  saves over the written-out copy; the extension stores it into the vault
  a second after the last save (through a temp name, swapped in when
  complete). If the vault copy changed meanwhile, the save is kept beside
  it as "name (1)" and later saves of that document go to the copy. Locking
  stores anything still waiting first (within 10 seconds). A save the
  extension never saw because iOS killed it in that second is lost with
  the next extension process, which deletes what it finds on start.
- **Locking.** Every lock path (button, quick action, auto-lock) asks the
  extension over XPC to store waiting saves and lock, then posts a Darwin
  notification it acts on in case the call didn't land, removes the
  domain, deletes its folder and checks it is gone (and says so in the app
  if it isn't). A new extension process wipes the folder before answering
  anything, and the app removes any leftover domain at launch and whenever
  it comes to the foreground with nothing shared. Any app can post that
  Darwin notification; the worst it can do is lock the vault early.
- **Auto-lock while the app is suspended.** The extension checks the
  deadline (D19) on every Files operation and every 15 seconds while it
  runs: the user's delay, or 2 minutes for "Immediately", after the later
  of leaving VaultPony and the last Files activity, and never more than 1
  hour after leaving. Both processes read the same clock (`FilesGate`:
  CLOCK_MONOTONIC, which keeps counting in sleep; stamps from before a
  reboot are discarded); the app writes a heartbeat while in front so a
  crash in front still starts it. A suspended extension doesn't run, so
  past the deadline its keys and any written-out files stay until it runs
  again (and then locks at once) or iOS ends it, or until the app's next
  launch or return to the foreground.
- **Two writers, one volume.** The app and the extension each mount the
  volume. `FilesGate` serializes every core call with a `flock` in the app
  group, makes the other side remount after a write, and carries a
  read-only bit so a hidden-volume protection trip in either process stops
  writes in both. The app keeps a background task around each gated call
  so it is never suspended holding that lock.
- **What Files and other apps learn.** The location is always named
  "VaultPony", for hidden and outer volumes alike, under a random domain id
  per unlock. Item identifiers are encrypted paths under a key minted per
  unlock, meaningless after lock. The working set is empty, so vault items
  never reach Recents, tags, favorites or Spotlight, and no thumbnails are
  provided. Outside VaultPony's control: Files' own databases, a folder the
  user drags to Favorites, copies other apps make, and anything the system
  caches from files while they are open. These can't be inspected on a
  stock device.
- **Copy-mode vaults** (opened as a local copy) get no Files access: their
  changes reach the real container only through a prompt at lock that Files
  can't show.

Reviewed: rc3, code only. The on-device checks (extension memory, idle
kill, fd passing, storage locations, residue after lock) are part of the
rc3 device test.

## 10. Share into a vault, thumbnails, playback, vault list (2.0.0 rc4)

**Share extension (`VaultPonyShare`, plan 5.1).** "Save to VaultPony" in
the share sheet runs in the sharing app's context. It never opens a vault,
never links the core and never sees a password or key. It copies each
shared item, file to file (`loadFileRepresentation`, never a whole file in
memory), into `<app group>/Share/<random UUID>/files/`, writes a manifest
holding only the file names, then opens VaultPony with
`vaultpony://share?token=<UUID>`. Shared text that came without a file is
saved as "Shared text.txt". Items that can't be staged are left out.

- **Plaintext on disk until claimed.** The shared files sit unencrypted in
  the app group from the moment the extension stages them until the app
  claims them. Everything staged has `FileProtectionType.complete` (folders
  and files) and is excluded from backup. The app claims a share as soon as
  it hears of it: the folder is moved (not copied) into the app's own
  temporary directory, with complete protection, before anything else runs.
  The claimed copy is deleted when the import ends, when the user cancels,
  whenever an unlocked vault locks, and at the next launch if the app was
  killed first. A link that arrives while the app is still coming to the
  front is not claimed at once: the share stays staged until the app is
  active (and any auto-lock due on return has run), then the pick-up
  claims it.
- **Sweep.** If the extension couldn't open the app, the share stays staged.
  On every launch and return to the foreground the app picks up a staged
  share younger than 10 minutes and deletes older ones. A share the user
  never comes back for therefore stays on disk (complete protection) until
  the next time VaultPony runs.
- **The URL.** Any app can open `vaultpony://share?token=...`. The app
  accepts only a UUID token, uses it only to name a folder under the app
  group's `Share/` directory, and only imports after the user picks a vault
  and a folder. The worst another app can do is make VaultPony look for a
  folder that isn't there.
- **Import.** The files go through the existing bulk import (temporary
  names, keep-both on collisions, space check, auto-lock hold). Nothing
  about the share is written to the vault list or app prefs.

**Grid thumbnails (plan 5.3).** Images up to 20 MB are read through
`Vault.readAt` and downsampled in memory with ImageIO
(`kCGImageSourceShouldCache` off). Thumbnails live only in an in-memory
cache of about 32 MB that is cleared at every lock; they are never written
to disk, and VaultPony provides none to Files.

**Search (plan 5.3).** "Whole vault" walks the tree in memory through the
gated `Vault.list`, stops when the search changes, the screen goes or the
vault locks, and never shows the temporary names Files or an import use.

**Playback (plan 5.2).** Video and audio stream from the vault through an
`AVAssetResourceLoaderDelegate` that answers each byte range with
`Vault.readAt`; no temp file is written. The asset URL carries a random id,
not the file name. The player controller has Now Playing updates and
picture in picture turned off, and VaultPony sets no
`MPNowPlayingInfoCenter` info and no remote commands, so no title or
artwork reaches the Lock Screen or Control Center. AVFoundation's own
in-memory buffers are outside VaultPony's control. Players stop at lock.

**Vault list (plan 5.4).** Settings > Vault list: "Show names" (the
default), "Hide names" (the list shows "Vault 1", "Vault 2"; stored names
are wiped and new entries store none, but the security-scoped bookmark
still records where each file is, which the footer says), and "Don't keep"
(after a confirmation every entry is deleted with its Face ID credential;
from then on entries live in memory only, never in `recents.json`, and a
vault leaves the list when it locks). No-trace mode stays a separate,
broader setting: while it is on, vaults opened are kept in memory only and
leave the list at lock, but entries saved before, and their Face ID
unlocks, are left alone (only "Don't keep" deletes them). A hash
picked by hand on the unlock screen is remembered with the entry (as its
name, never a key or password), never what Auto found, never from a failed
unlock, and never while the list keeps nothing.

Reviewed: rc4, code only. On-device checks: the share hand-off from Photos
and Files (large videos included), the extension's memory use, residue in
the app group and the app's tmp/ after import, cancel and lock, Now
Playing with a video open, and thumbnails dropped at lock.

## 11. Camera capture into a vault (2.0.0 rc5)

**Where it is.** "Take photo" and "Record video" are in the browser's add
menu, only for a writable volume, and only in the main app: neither the
File Provider nor the Share extension can open the camera, and neither
declares a camera or microphone usage string.

**Permissions.** The camera is asked for the first time the camera screen
opens, the microphone only the first time Video is chosen. Without the
microphone, video records without sound. VaultPony asks for no Photos
access at all, so nothing can be saved to or read from the photo library.

**Photos stay in memory.** `AVCapturePhotoOutput` returns the JPEG as bytes
(`fileDataRepresentation()`), which are written into the vault through
`Vault.writeAt`. No location is added; the JPEG carries the camera's usual
EXIF fields only.

**Video never touches the disk outside the vault.** Frames and sound from
`AVCaptureVideoDataOutput` and `AVCaptureAudioDataOutput` go into an
`AVAssetWriter` created with a content type and no output URL, using the
Apple HLS profile. It hands back fragmented MP4 in memory through its
delegate: the init segment, then a segment about every 2 seconds. Each
segment is appended, in order, to a temporary file in the vault. There is
no temp file in the app's container, tmp/, caches or the app group at any
point. AVFoundation's own in-memory buffers are outside VaultPony's
control, as for playback (section 10).

**Names and partial files.** A capture is written under a hidden
".vaultpony-<token>.part" name and `replace`d to "IMG_yyyyMMdd_HHmmss.jpg"
or "VID_yyyyMMdd_HHmmss.mp4" (local time; "name (1)" when taken) only when
complete, so a crash leaves at worst a hidden partial file inside the vault,
which the next import into that folder deletes.

**Locks.** A recording or save in progress holds off the auto-lock like a
copy (D13). Any lock that still happens (Lock vaults, background time
running out) first stops the recording and removes its temporary file,
then the camera closes. Going to the background finishes and keeps a
recording while the vault is still unlocked.

Reviewed: rc5, code only. On-device checks still to do: no new files in
the app container, tmp/ or Photos after photos and videos; recorded videos
play in VaultPony and other players; lock and backgrounding during a
recording.
