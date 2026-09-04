#!/bin/bash
# verify-local.sh — offline build and bundle checks; optional safe launch smoke test
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SMOKE_LAUNCH=0
case "${1:-}" in
  "") ;;
  --smoke-launch) SMOKE_LAUNCH=1 ;;
  *)
    echo "usage: scripts/verify-local.sh [--smoke-launch]" >&2
    exit 2
    ;;
esac

scripts/build.sh

swiftc -O -swift-version 5 -parse-as-library \
  -o build/ScheduleResolverTests \
  src/ScheduleResolver.swift scripts/test_schedule.swift
build/ScheduleResolverTests

APP="outputs/Time.Sleep.app"
EXECUTABLE="$APP/Contents/MacOS/TimeSleep"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
for strings_file in "$APP"/Contents/Resources/*.lproj/InfoPlist.strings; do
  plutil -lint "$strings_file" >/dev/null
done

codesign --verify --deep --strict --verbose=2 "$APP"

if ! file "$EXECUTABLE" | grep -q "arm64"; then
  echo "error: executable is not arm64" >&2
  exit 1
fi

if ! otool -l "$EXECUTABLE" | grep -A 5 LC_BUILD_VERSION | grep -q "minos 14.0"; then
  echo "error: executable minimum macOS version is not 14.0" >&2
  exit 1
fi

ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>&1 || true)"
if grep -q "com.apple.developer.usernotifications.time-sensitive" <<<"$ENTITLEMENTS"; then
  echo "error: ad-hoc build contains the restricted Time Sensitive entitlement" >&2
  exit 1
fi

test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/TimeSleepAlert.wav"

if [[ "$SMOKE_LAUNCH" -eq 1 ]]; then
  mkdir -p .work/logs
  SMOKE_LOG=".work/logs/smoke-$(date +%Y%m%d-%H%M%S).log"
  "$EXECUTABLE" --dry-run >"$SMOKE_LOG" 2>&1 &
  TIMESLEEP_SMOKE_PID=$!

  cleanup_smoke() {
    if kill -0 "$TIMESLEEP_SMOKE_PID" 2>/dev/null; then
      kill -TERM "$TIMESLEEP_SMOKE_PID" 2>/dev/null || true
      wait "$TIMESLEEP_SMOKE_PID" 2>/dev/null || true
    fi
  }
  trap cleanup_smoke EXIT INT TERM

  /bin/sleep 2
  if ! kill -0 "$TIMESLEEP_SMOKE_PID" 2>/dev/null; then
    echo "error: app did not survive the smoke launch; see $SMOKE_LOG" >&2
    exit 1
  fi

  cleanup_smoke
  trap - EXIT INT TERM
  echo "smoke launch: passed (dry-run, no power action)"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
echo "local verification: passed (Time.Sleep $VERSION build $BUILD)"
