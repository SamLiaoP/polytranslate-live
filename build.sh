#!/bin/zsh
# PolyTranslate Live：編譯 + 組 .app bundle + ad-hoc 簽名。不需要 Xcode，只要 Command Line Tools（SDK 26+）。
#   ./build.sh          編譯
#   ./build.sh run      編譯後啟動
set -e
cd "$(dirname "$0")"

APP_NAME="PolyTranslateLive"
BUNDLE_ID="dev.samliao.polytranslatelive"
OUT="build"
APP="$OUT/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
SDKV="$(xcrun --show-sdk-version | cut -d. -f1)"

if [ "$SDKV" -lt 26 ]; then
  echo "✗ macOS SDK $SDKV < 26，SpeechAnalyzer 需要 SDK 26。請更新 Command Line Tools。"
  exit 1
fi

mkdir -p "$OUT"
echo "→ 編譯（SDK $(xcrun --show-sdk-version)，$(swiftc --version 2>/dev/null | head -1)）"
swiftc -O -sdk "$SDK" -target arm64-apple-macos26.4 -swift-version 5 \
  Sources/*.swift -o "$OUT/$APP_NAME"

echo "→ 組 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$OUT/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "→ 簽名（ad-hoc）"
codesign --force --deep -s - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

echo "✓ $APP"
if [ "$1" = "run" ]; then
  open "$APP"
fi
