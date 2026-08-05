#!/usr/bin/env bash
# Materializes the fixture corpus into ./fixtures (gitignored) for
# VaultPonyTests. Fixtures are the spec (PLAN.md); this script never
# generates them — regeneration needs a Linux box with the VeraCrypt CLI,
# see VaultPonyCore/tools/gen-fixtures/README.md. Instead it copies the
# local cache VaultPonyCore keeps at its own ./fixtures, or
# $VAULTPONY_FIXTURES if set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/fixtures"

if [[ -n "${VAULTPONY_FIXTURES:-}" ]]; then
  SRC="$VAULTPONY_FIXTURES"
elif [[ -d "$ROOT/../VaultPonyCore/fixtures" ]]; then
  SRC="$ROOT/../VaultPonyCore/fixtures"
elif [[ -d "$ROOT/VaultPonyCore/fixtures" ]]; then
  SRC="$ROOT/VaultPonyCore/fixtures"
else
  echo "error: no fixture cache found (checked \$VAULTPONY_FIXTURES, ../VaultPonyCore/fixtures, ./VaultPonyCore/fixtures)" >&2
  echo "see VaultPonyCore/tools/gen-fixtures/README.md to regenerate from a pinned VeraCrypt checkout" >&2
  exit 1
fi

mkdir -p "$DEST"
cp -v "$SRC"/*.vc "$SRC/manifest.json" "$DEST/"
echo "== fixtures ready at $DEST =="
