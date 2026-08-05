#!/usr/bin/env bash
# Builds VaultPonyCore's vault-ffi crate for iOS device + simulator,
# generates the Swift bindings, and assembles Generated/VaultFFI.xcframework.
#
# Core resolution order: $VAULTPONY_CORE, then the sibling checkout
# (../VaultPonyCore), then the git submodule (./VaultPonyCore) — mirrors
# VaultPonyAndroid's Gradle resolution so both apps track the same core the
# same way.
#
# NOTE (P0): this script is unverified until the first real run on a Mac
# with rustup + Xcode. The uniffi-bindgen output filenames in particular are
# copied from the crate's doc comments and may need adjusting once run for
# real — expect the first ./scripts/build-core.sh to need a fix or two.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED="$ROOT/Generated"

if [[ -n "${VAULTPONY_CORE:-}" ]]; then
  CORE="$VAULTPONY_CORE"
elif [[ -d "$ROOT/../VaultPonyCore/core/vault-ffi" ]]; then
  CORE="$ROOT/../VaultPonyCore"
elif [[ -d "$ROOT/VaultPonyCore/core/vault-ffi" ]]; then
  CORE="$ROOT/VaultPonyCore"
else
  echo "error: could not find VaultPonyCore (checked \$VAULTPONY_CORE, ../VaultPonyCore, ./VaultPonyCore)" >&2
  exit 1
fi
echo "== VaultPonyCore: $CORE =="

DEVICE_TARGET=aarch64-apple-ios
SIM_TARGET=aarch64-apple-ios-sim

cd "$CORE"
for target in "$DEVICE_TARGET" "$SIM_TARGET"; do
  echo "== cargo build ($target) =="
  cargo build -p vault-ffi --release --locked --target "$target"
done

echo "== generating Swift bindings =="
rm -rf "$GENERATED"
mkdir -p "$GENERATED/bindings" "$GENERATED/headers"
cargo run -p vault-ffi --features cli --release --bin uniffi-bindgen -- generate \
  --library "target/$DEVICE_TARGET/release/libvault_ffi.a" \
  --language swift \
  --out-dir "$GENERATED/bindings"

# uniffi emits the .swift file plus a C header and modulemap alongside it;
# move the C parts into a headers dir for the xcframework step.
mv "$GENERATED/bindings/"*.h "$GENERATED/headers/"
mv "$GENERATED/bindings/"*.modulemap "$GENERATED/headers/module.modulemap"

echo "== assembling VaultFFI.xcframework =="
rm -rf "$GENERATED/VaultFFI.xcframework"
xcodebuild -create-xcframework \
  -library "target/$DEVICE_TARGET/release/libvault_ffi.a" -headers "$GENERATED/headers" \
  -library "target/$SIM_TARGET/release/libvault_ffi.a" -headers "$GENERATED/headers" \
  -output "$GENERATED/VaultFFI.xcframework"

echo "== done: $GENERATED =="
