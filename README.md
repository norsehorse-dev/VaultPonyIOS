# VaultPonyIOS

VeraCrypt-compatible encrypted vaults on iPhone and iPad — open, create, and
edit containers, including hidden volumes, backed by the shared Rust core
(VaultPonyCore). Swift and SwiftUI over a UniFFI boundary.

Not affiliated with or endorsed by IDRIX. VeraCrypt is a registered trademark
of IDRIX.

**Status: feature-complete (P0–P6), release prep underway (P7).**

## Layout

See `PLAN.md` for the full plan, phasing, and architecture. Short version:

| Path | What |
|---|---|
| `VaultPony/` | app sources: App, CoreBridge, Storage, Security, UI, Resources |
| `VaultPonyTests/` | fixture-driven core-through-FFI tests + unit tests |
| `VaultPonyUITests/` | smoke flows |
| `VaultPonyCore/` | the shared Rust core, as a sibling checkout or git submodule |
| `scripts/build-core.sh` | builds the core for iOS, generates Swift bindings, assembles the xcframework |
| `scripts/fetch-fixtures.sh` | materializes the fixture corpus for tests |
| `project.yml` | XcodeGen spec — the `.xcodeproj` is generated, not committed |

## Building

Prereqs: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), rustup
with the toolchain pinned by VaultPonyCore, and the iOS Rust targets:

    rustup target add aarch64-apple-ios aarch64-apple-ios-sim

The Rust core is a separate repo (VaultPonyCore), resolved as a sibling
checkout at `../VaultPonyCore` when present, otherwise the git submodule at
`./VaultPonyCore`. Clone with `--recursive`, or after cloning run:

    git submodule update --init --recursive

Then:

    ./scripts/build-core.sh   # builds the core, generates bindings + xcframework
    xcodegen generate         # generates VaultPony.xcodeproj
    open VaultPony.xcodeproj

`scripts/build-core.sh` also runs as an Xcode pre-build phase, so day-to-day
iteration after the first build is just Cmd-R.

## Design

`PLAN.md` is the source of truth for scope and phasing. Security posture:
see `THREAT_MODEL-IOS.md`, which layers iOS-specific deltas on top of
VaultPonyCore's `THREAT_MODEL.md`.

## License

Apache-2.0. See `LICENSE`.
