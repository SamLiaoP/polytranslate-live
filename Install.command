#!/bin/bash
# PolyTranslate Live 一鍵安裝／更新：在 Finder 點兩下這個檔案即可。
# 做的事：檢查機器與 Command Line Tools → （repo 有新版就 git pull）→ ./build.sh install → 打開 App。
# 再點一次就是更新。POLY_DRY_RUN=1 只做檢查不編譯（測試用）。
set -u
cd "$(dirname "$0")" || exit 1

say_() { printf "\n%s\n" "$*"; }
die() { say_ "✗ $*"; say_ "按 Enter 關閉。 / Press Enter to close."; read -r _; exit 1; }

say_ "PolyTranslate Live 安裝程式 / Installer"
say_ "資料夾：$(pwd)"

# 1. 硬體與系統版本
if [ "$(uname -m)" != "arm64" ]; then
  die "需要 Apple Silicon（M1 以上）的 Mac。 / This app needs an Apple Silicon Mac."
fi
OSVER="$(sw_vers -productVersion)"
MAJOR="${OSVER%%.*}"; REST="${OSVER#*.}"; MINOR="${REST%%.*}"
if [ "$MAJOR" -lt 26 ] || { [ "$MAJOR" -eq 26 ] && [ "${MINOR:-0}" -lt 4 ]; }; then
  die "需要 macOS 26.4 以上，目前是 $OSVER。請先到 系統設定 › 一般 › 軟體更新。 / Needs macOS 26.4 or later (you have $OSVER)."
fi

# 2. Command Line Tools（只要這個，不用 Xcode）
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --show-sdk-path >/dev/null 2>&1; then
  say_ "還沒有 Xcode Command Line Tools，現在幫你叫出安裝視窗（約 1–2 GB，不用裝 Xcode）。"
  say_ "Command Line Tools are missing. The installer dialog will open now (no Xcode needed)."
  xcode-select --install >/dev/null 2>&1 || true
  die "裝好 Command Line Tools 之後，再點一次 Install.command。 / After it finishes, double-click Install.command again."
fi

# 3. 有 git repo 就先拉最新版（失敗不致命，例如沒網路）
if [ -d .git ] && command -v git >/dev/null 2>&1; then
  say_ "→ 檢查更新 / Checking for updates"
  git pull --ff-only 2>&1 | tail -1 || true
fi

if [ "${POLY_DRY_RUN:-0}" = "1" ]; then say_ "（dry run，略過編譯）"; exit 0; fi

# 4. 簽名憑證：有的話之後更新不必重新授權「螢幕與系統錄音」。第一次會問一次要不要建（要輸入系統密碼）。
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q '"PolyTranslate Live Dev"'; then
  if [ -t 0 ]; then
    printf "\n要建立本機簽名憑證嗎？建了之後更新 App 不必重新授權系統錄音，過程會要一次系統密碼。[Y/n] "
    printf "\nCreate a local signing certificate so updates keep their permissions? Asks for your password once. [Y/n] "
    read -r ans
    case "${ans:-Y}" in [Nn]*) ;; *) bash tools/make_cert.sh || say_ "憑證沒建成，先用 ad-hoc 簽名繼續。 / Certificate skipped; continuing with ad-hoc signing." ;; esac
  fi
fi

# 5. 編譯並安裝
say_ "→ 編譯並安裝（第一次約 1 分鐘）/ Building and installing"
if ! ./build.sh install; then
  die "編譯失敗。把上面的訊息貼給開發者。 / Build failed; please send the output above to the developer."
fi

# 6. 打開
APP="/Applications/PolyTranslate Live.app"
[ -d "$APP" ] || APP="$HOME/Applications/PolyTranslate Live.app"
open "$APP"
say_ "✓ 裝好了，App 已打開。第一次按「開始」時請允許：麥克風、語音辨識、螢幕與系統錄音，然後 ⌘Q 重開一次。"
say_ "✓ Installed and launched. On the first Start, allow Microphone, Speech Recognition and Screen & System Audio Recording, then quit and relaunch once."
say_ "之後要更新：再點一次 Install.command。 / To update later: double-click Install.command again."
say_ "按 Enter 關閉。 / Press Enter to close."
read -r _
