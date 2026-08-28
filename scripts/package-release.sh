#!/bin/bash
# package-release.sh — create a local GitHub Release archive and SHA-256 checksum
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# A Release package must pass a real process launch, not only static code-sign checks.
scripts/verify-local.sh --smoke-launch

APP="outputs/Time.Sleep.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHIVE_NAME="Time.Sleep-${VERSION}-macOS-arm64.zip"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"
STAGING_DIR="build/release"

rm -f "outputs/$ARCHIVE_NAME" "outputs/$CHECKSUM_NAME"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP" "$STAGING_DIR/Time.Sleep.app"
cp LICENSE "$STAGING_DIR/LICENSE"

ditto -c -k --sequesterRsrc "$STAGING_DIR" "outputs/$ARCHIVE_NAME"
unzip -t "outputs/$ARCHIVE_NAME" >/dev/null

(
  cd outputs
  shasum -a 256 "$ARCHIVE_NAME" >"$CHECKSUM_NAME"
)

echo "release archive: $ROOT/outputs/$ARCHIVE_NAME"
echo "checksum:       $ROOT/outputs/$CHECKSUM_NAME"
