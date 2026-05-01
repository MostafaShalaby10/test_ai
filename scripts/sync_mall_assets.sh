#!/usr/bin/env bash
# Sync mall data from sign_surveyor into the Flutter app's assets/mall.
#
# Copies (does NOT symlink — Flutter's iOS asset bundler doesn't follow
# symlinks reliably):
#   sign_surveyor/shops.json   → assets/mall/shops.json
#   sign_surveyor/output/*.bin → assets/mall/features/*.bin
#
# Validates each .bin starts with the SSF1 magic. Prints copied/skipped counts.
#
# Usage: bash scripts/sync_mall_assets.sh [path-to-sign_surveyor]
#   default surveyor path: ../sign_surveyor (sibling of test_ai)

set -euo pipefail

# Resolve repo root (script lives in <repo>/scripts/).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SURVEYOR="${1:-$(cd "$REPO_ROOT/../sign_surveyor" && pwd)}"

ASSET_ROOT="$REPO_ROOT/assets/mall"
FEATURES_DIR="$ASSET_ROOT/features"
TEST_IMAGES_DIR="$ASSET_ROOT/test_images"

if [[ ! -d "$SURVEYOR" ]]; then
  echo "ERROR: surveyor directory not found at $SURVEYOR" >&2
  exit 1
fi
if [[ ! -f "$SURVEYOR/shops.json" ]]; then
  echo "ERROR: $SURVEYOR/shops.json not found" >&2
  exit 1
fi

mkdir -p "$FEATURES_DIR" "$TEST_IMAGES_DIR"

echo "Syncing mall assets:"
echo "  from: $SURVEYOR"
echo "  to:   $ASSET_ROOT"
echo

# 1) Registry.
cp "$SURVEYOR/shops.json" "$ASSET_ROOT/shops.json"
echo "✓ shops.json"

# 2) Per-shop SSF1 binaries.
copied=0
skipped=0
shopt -s nullglob
for src in "$SURVEYOR/output/"*.bin; do
  base="$(basename "$src")"
  dst="$FEATURES_DIR/$base"

  # Verify SSF1 magic before copying — guards against corrupted/non-SSF1 files.
  magic="$(head -c 4 "$src" 2>/dev/null || true)"
  if [[ "$magic" != "SSF1" ]]; then
    echo "✗ $base: bad magic (\"$magic\"), skipping"
    skipped=$((skipped + 1))
    continue
  fi

  cp "$src" "$dst"
  size=$(wc -c < "$dst" | tr -d ' ')
  echo "✓ $base ($size bytes)"
  copied=$((copied + 1))
done
shopt -u nullglob

echo
echo "Done. Copied: $copied feature file(s), skipped: $skipped, registry: 1."

# 3) Optional reference test images for the in-app self-test (Phase 3.3).
# Looks for $SURVEYOR/test_images/<shop_id>.jpg or .jpeg or .png and copies.
# Skipping is fine — the self-test simply has nothing to run for that shop.
test_copied=0
shopt -s nullglob
for src in "$SURVEYOR/test_images/"*.{jpg,jpeg,png}; do
  base="$(basename "$src")"
  cp "$src" "$TEST_IMAGES_DIR/$base"
  echo "✓ test_images/$base"
  test_copied=$((test_copied + 1))
done
shopt -u nullglob
if [[ $test_copied -gt 0 ]]; then
  echo "Copied $test_copied test image(s)."
fi

echo "Run 'flutter pub get' if you added a new shop."
