#!/bin/zsh
# PolyTranslate Live：編譯 + 組 .app bundle + 簽名 + 安裝到 /Applications。
# 不需要 Xcode，只要 Command Line Tools（SDK 26+）。
#
#   ./build.sh            編譯到 build/PolyTranslateLive.app
#   ./build.sh install    編譯並安裝到 /Applications/PolyTranslate Live.app（寫不進去時退回 ~/Applications）
#   ./build.sh run        編譯、安裝、啟動
#   ./build.sh test       編譯並執行 tests/ 裡的單元測試（ScriptDetector、Arbiter）
set -e
cd "$(dirname "$0")"

APP_NAME="PolyTranslateLive"
DISPLAY_NAME="PolyTranslate Live"
BUNDLE_ID="dev.samliao.polytranslatelive"
OUT="build"
APP="$OUT/$APP_NAME.app"
# Finder 側欄的「應用程式」是 /Applications；~/Applications 只有 Launchpad 和 Spotlight 看得到，使用者會找不到。
INSTALL_DIR="/Applications"
[ -w "$INSTALL_DIR" ] || INSTALL_DIR="$HOME/Applications"
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
# CFBundleVersion 蓋成編譯時間，「關於」視窗一眼就看得出跑的是不是剛編的版本。
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M)" "$APP/Contents/Info.plist"
# 再記下 git commit（有未 commit 的改動就加 -dirty），設定頁最下面會顯示「0.3.0 · 20261027.1345 · 9d9034a」。
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
/usr/libexec/PlistBuddy -c "Add :PTLBuildCommit string $COMMIT" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :PTLBuildCommit $COMMIT" "$APP/Contents/Info.plist"
cp "$OUT/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# 簽名身分：有自簽憑證「PolyTranslate Live Dev」（tools/make_cert.sh 會建）就用它，重建後授權才會保留；
# 沒有就 ad-hoc（每次重建 cdhash 都變，「螢幕與系統錄音」要重新授權）。也可用 CODESIGN_IDENTITY 指定。
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"PolyTranslate Live Dev"'; then
  SIGN_ID="PolyTranslate Live Dev"
fi
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="-"
  echo "→ 簽名（ad-hoc；想讓授權跨重建保留請先跑 tools/make_cert.sh）"
else
  echo "→ 簽名（$SIGN_ID）"
fi
codesign --force --deep -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
echo "✓ $APP"

if [ "$1" = "install" ] || [ "$1" = "run" ]; then
  echo "→ 安裝到 $INSTALLED"
  mkdir -p "$INSTALL_DIR"
  # 先關掉正在跑的舊版（等它真的結束），再整個換掉，重跑就是更新。
  if pkill -x "$APP_NAME" 2>/dev/null; then
    for _ in $(seq 1 50); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
  fi
  # 記住舊版的簽章條件（TCC 用它認 App）。簽章換了（例如 ad-hoc → 憑證、或 ad-hoc 重建）就得清掉舊授權，
  # 否則「螢幕與系統錄音」在系統設定裡看起來是開的，實際上對不上新版，永遠被拒。
  OLD_REQ=""; [ -d "$INSTALLED" ] && OLD_REQ="$(codesign -d -r- "$INSTALLED" 2>&1 | grep '^designated' || true)"
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  # 以前裝在 ~/Applications 的舊版順手清掉，免得 Spotlight 跑出兩個。
  if [ "$INSTALL_DIR" = "/Applications" ] && [ -d "$HOME/Applications/$DISPLAY_NAME.app" ]; then
    rm -rf "$HOME/Applications/$DISPLAY_NAME.app"
    echo "  已移除舊的 ~/Applications/$DISPLAY_NAME.app"
  fi
  xattr -cr "$INSTALLED" 2>/dev/null || true
  # 複製後重新簽名，確保安裝位置的簽章完整（TCC 權限綁定這個路徑）。
  codesign --force --deep -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$INSTALLED"
  codesign --verify --strict "$INSTALLED"
  NEW_REQ="$(codesign -d -r- "$INSTALLED" 2>&1 | grep '^designated' || true)"
  if [ -n "$OLD_REQ" ] && [ "$OLD_REQ" != "$NEW_REQ" ]; then
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset AudioCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "  簽章變了，已清掉舊的「螢幕與系統錄音」授權；下次按「開始」macOS 會重新詢問，允許後 ⌘Q 重開。"
    TCC_RESET=1
  fi
  touch "$INSTALLED"
  # 向 Launch Services 登記，Finder／Spotlight 立刻看得到新版。
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$INSTALLED" 2>/dev/null || true
  echo "✓ 已安裝：$INSTALLED"
  echo "  Launchpad、Spotlight、Finder › 應用程式 都找得到。第一次啟動請用這個安裝版本，權限才會記在正確的路徑上。"
fi

if [ "$1" = "run" ]; then
  open "$INSTALLED"
fi
