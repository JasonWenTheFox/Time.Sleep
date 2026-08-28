#!/bin/bash
# build.sh — 编译并打包 Time.Sleep.app（无需 Xcode 工程）
# 产物: outputs/Time.Sleep.app ；日志: .work/logs/build-*.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p .work/logs outputs build
LOG=".work/logs/build-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "== Time.Sleep build $(date '+%Y-%m-%d %H:%M:%S') =="

# 1. 生成图标（1024 png → iconset → icns）
echo "[1/5] generating icon..."
swift scripts/gen_icon.swift build/icon_1024.png
rm -rf build/AppIcon.iconset
mkdir build/AppIcon.iconset
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" build/icon_1024.png --out "build/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
  sz2=$((sz * 2))
  sips -z "$sz2" "$sz2" build/icon_1024.png --out "build/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

# 2. 生成增强提醒音（源码生成，避免把本机构建资源提交到 Git）
echo "[2/5] generating alert sound..."
swift scripts/gen_alert_sound.swift build/TimeSleepAlert.wav

# 3. 编译（Swift 5 语言模式；单文件含 @main 需要 -parse-as-library；最低 macOS 14）
echo "[3/5] compiling..."
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -o build/TimeSleep src/TimeSleepApp.swift

# 4. 组装 .app
echo "[4/5] assembling bundle..."
APP="build/Time.Sleep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/TimeSleep "$APP/Contents/MacOS/TimeSleep"
cp src/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp build/TimeSleepAlert.wav "$APP/Contents/Resources/TimeSleepAlert.wav"
for lproj in src/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

# 5. ad-hoc 签名并校验
# 注意：Time Sensitive 是受限制 entitlement，ad-hoc 签名携带它会被 AMFI 在启动时拒绝。
echo "[5/5] codesigning..."
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

rm -rf outputs/Time.Sleep.app
cp -R "$APP" outputs/Time.Sleep.app

echo "OK: $ROOT/outputs/Time.Sleep.app"
echo "install: cp -R outputs/Time.Sleep.app /Applications/"
