#!/bin/bash
# PolyTranslate Live 一鍵安裝／更新：在 Finder 點兩下這個檔案即可。
# 做的事：檢查機器與 Command Line Tools → （repo 有新版就 git pull）→ ./build.sh install → 打開 App。
# 不會要使用者的密碼，不碰鑰匙圈。
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

# 4. 簽名：一般使用者用 ad-hoc，不碰鑰匙圈、不要密碼。代價是每次更新後 macOS 會把它當新 App，
#    「螢幕與系統錄音」要再允許一次；build.sh 會比對新舊簽章，變了就把舊授權清掉，讓系統直接重新詢問，不會卡在「開著但沒作用」。
#    開發者想讓授權跨更新保留，可以自己跑 tools/make_cert.sh（會要一次系統密碼）。
APP="/Applications/PolyTranslate Live.app"
[ -d "$APP" ] || APP="$HOME/Applications/PolyTranslate Live.app"
WAS_INSTALLED=0; OLD_REQ=""
if [ -d "$APP" ]; then WAS_INSTALLED=1; OLD_REQ="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"; fi

# 5. 編譯並安裝
say_ "→ 編譯並安裝（第一次約 1 分鐘）/ Building and installing"
if ! ./build.sh install; then
  die "編譯失敗。把上面的訊息貼給開發者。 / Build failed; please send the output above to the developer."
fi

# 6. 更新後若簽章變了（ad-hoc 每次重建都會變），build.sh 已把舊的系統錄音授權清掉；這裡只提醒使用者。
APP="/Applications/PolyTranslate Live.app"
[ -d "$APP" ] || APP="$HOME/Applications/PolyTranslate Live.app"
NEW_REQ="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
if [ "$WAS_INSTALLED" = "1" ] && [ "$OLD_REQ" != "$NEW_REQ" ]; then
  say_ "已更新。因為 App 的簽章變了，下次按「開始」時 macOS 會再問一次「螢幕與系統錄音」，允許後 ⌘Q 重開即可。"
  say_ "Updated. The app's signature changed, so macOS will ask for Screen & System Audio Recording once more on the next Start; allow it, then quit and relaunch."
fi

# 7. 打開
open "$APP"
say_ "✓ 裝好了，App 已打開。第一次按「開始」時請允許：麥克風、語音辨識、螢幕與系統錄音，然後 ⌘Q 重開一次。"
say_ "✓ Installed and launched. On the first Start, allow Microphone, Speech Recognition and Screen & System Audio Recording, then quit and relaunch once."
say_ "這個安裝程式不會要你的密碼；只有 macOS 自己的權限視窗會出現。 / This installer never asks for your password; only macOS's own permission dialogs appear."
say_ "之後要更新：再點一次 Install.command。 / To update later: double-click Install.command again."
say_ "按 Enter 關閉。 / Press Enter to close."
read -r _
