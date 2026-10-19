#!/bin/zsh
# PolyTranslate Live：編譯 + 組 .app bundle + ad-hoc 簽名 + 安裝到 ~/Applications。
# 不需要 Xcode，只要 Command Line Tools（SDK 26+）。
#
#   ./build.sh            編譯到 build/PolyTranslateLive.app
#   ./build.sh install    編譯並安裝到 ~/Applications/PolyTranslate Live.app（Launchpad / Spotlight 找得到）
#   ./build.sh run        編譯、安裝、啟動
#   ./build.sh test       編譯並執行 tests/ 裡的單元測試（ScriptDetector、Arbiter）
set -e
cd "$(dirname "$0")"

APP_NAME="PolyTranslateLive"
DISPLAY_NAME="PolyTranslate Live"
BUNDLE_ID="dev.samliao.polytranslatelive"
OUT="build"
APP="$OUT/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED="$INSTALL_DIR/$DISPLAY_NAME.app"
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"

if [ -z "$SDK" ]; then
  echo "✗ 找不到 macOS SDK。請先安裝 Command Line Tools：xcode-select --install"
  exit 1
fi
SDKV="$(xcrun --show-sdk-version | cut -d. -f1)"
if [ "$SDKV" -lt 26 ]; then
  echo "✗ macOS SDK $SDKV < 26，SpeechAnalyzer 需要 SDK 26。請更新 Command Line Tools（軟體更新）。"
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "✗ 只支援 Apple Silicon。"
  exit 1
fi

mkdir -p "$OUT"

if [ "$1" = "test" ]; then
  echo "→ 編譯測試"
  # main.swift 有 top-level code，換成測試的主程式；其餘原始碼全部一起編。
  swiftc -sdk "$SDK" -target arm64-apple-macos26.4 -swift-version 5 \
    $(ls Sources/*.swift | grep -v '/main.swift$') tests/main.swift -o "$OUT/tests"
  echo "→ 執行"
  "$OUT/tests"
  exit $?
fi

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

if [ "$1" = "install" ] || [ "$1" = "run" ]; then
  echo "→ 安裝到 $INSTALLED"
  mkdir -p "$INSTALL_DIR"
  # 先關掉正在跑的舊版，否則覆蓋會失敗。
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  xattr -cr "$INSTALLED" 2>/dev/null || true
  # 複製後重新簽名，確保安裝位置的簽章完整（TCC 權限綁定這個路徑）。
  codesign --force --deep -s - --identifier "$BUNDLE_ID" "$INSTALLED"
  codesign --verify --strict "$INSTALLED"
  touch "$INSTALLED"
  echo "✓ 已安裝：$INSTALLED"
  echo "  Launchpad、Spotlight、Finder › 應用程式 都找得到。第一次啟動請用這個安裝版本，權限才會記在正確的路徑上。"
fi

if [ "$1" = "run" ]; then
  open "$INSTALLED"
fi
