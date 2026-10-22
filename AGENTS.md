# PolyTranslate Live — notes for AI coding agents

This file is for AI assistants (Claude Code, Codex, Cursor, Copilot, …) that a user has pointed at this
repository to install, run or modify the app. Humans: see README.md.

## What this is

A native macOS app (Swift, SwiftUI, AppKit) for real-time multilingual meeting translation.
Audio → Apple `SpeechAnalyzer` (one lane per language, in parallel) → confidence-based arbiter →
Apple `Translation.framework` → two-line subtitles per language pane. Everything runs on-device.

## Hard requirements (check before doing anything)

- macOS **26.4 or later** (`sw_vers -productVersion`), **Apple Silicon** (`uname -m` → `arm64`).
- Xcode **Command Line Tools with the macOS 26 SDK**: `xcrun --show-sdk-version` must print `26.x`.
  Install with `xcode-select --install`; update via System Settings › Software Update. **Full Xcode is not needed.**
- Homebrew, SwiftPM packages, CocoaPods: none needed. There are no third-party dependencies.

## Install

```bash
./build.sh install     # compiles with swiftc, assembles the .app, ad-hoc signs it,
                       # copies it to /Applications/PolyTranslate Live.app
open /Applications/PolyTranslate\ Live.app
```

`./build.sh` alone only builds `build/PolyTranslateLive.app`. `./build.sh run` builds, installs and launches.

## First launch: permissions the user must grant (cannot be automated)

1. **Microphone** — macOS prompts on first Start.
2. **Screen & System Audio Recording** — needed to capture audio the Mac is playing. macOS opens
   System Settings › Privacy & Security; after enabling, the app must be **quit and relaunched**.
3. Optional but recommended: System Settings › General › Language & Region › **Translation Languages** →
   download the languages used (e.g. English, Traditional Chinese). Without them translation falls back
   to Apple's online service (slower, needs network). The app shows a "Download language pack" button.

Run `tools/make_cert.sh` once to create a self-signed signing certificate; `build.sh` then uses it automatically and permissions survive rebuilds. Without it the app is ad-hoc signed, so rebuilding may make macOS treat it as a new app and ask for Screen
Recording again. Tell the user this is expected.

## Verify without permissions

Layout check without screen recording: `build/PolyTranslateLive.app/Contents/MacOS/PolyTranslateLive --snapshot 480x300 /tmp/shot.png`
opens a window of that size with sample subtitles, renders it to PNG after two seconds and quits (does not touch the saved
window frame). Use 1240x780, 720x450 and 480x300 to see the regular, compact and mini layouts (`Layout` in ContentView.swift).


```bash
say -v Samantha -o /tmp/en.wav --data-format=LEI16@16000 "Good morning everyone. Today we review the results."
/Applications/PolyTranslate\ Live.app/Contents/MacOS/PolyTranslateLive --test-wav /tmp/en.wav
sleep 20; tail -20 ~/Library/Logs/PolyTranslateLive.log
```

Expected log lines: `lane ready`, `[P1] final(system): …`, `[P1] translated: …`, `history saved`.
The test feed stops by itself. Logs live at `~/Library/Logs/PolyTranslateLive.log`.

The log normally records only events (lanes, arbiter decisions, translation errors), **not what was said**.
Lines containing recognized text or translations appear only with `--verbose` or in `--test-wav` mode.
The file rotates to `.log.1` once it exceeds 5 MB.

## Unit tests

```bash
./build.sh test        # compiles Sources/ (minus main.swift) + tests/main.swift with swiftc and runs it
```

Covers `ScriptDetector`, `LanguageMap` and the `Arbiter` (confidence vote, overlap trimming, `flush()` on stop).
No XCTest; it is a plain executable that exits non-zero on failure. Add cases to `tests/main.swift`.

## Where things are

| Path | Purpose |
|---|---|
| `Install.command` | double-click installer for end users: environment checks, `git pull`, `./build.sh install`, TCC reset on update, launch. Never asks for a password (`tools/make_cert.sh` is for developers only) |
| `Sources/` | all Swift sources; `main.swift` is the AppKit entry point (there is no Xcode project) |
| `Sources/RecognitionEngine.swift` | parallel lanes + `Arbiter` (confidence vote, overlap trimming, script checks) |
| `Sources/L10n.swift` | UI string table in English, Traditional Chinese, Japanese and Korean (one array per key, in that order); add keys here, never hard-code UI text |
| `tests/main.swift` | unit tests for the pure logic (run with `./build.sh test`) |
| `Sources/TaiwanWording.swift` | generated from OpenCC TWPhrases/TWVariants (Apache-2.0, `third_party/OpenCC-LICENSE.txt`) plus a few app rules; applied to zh-Hant translations |
| `Sources/SessionRecorder.swift` | writes each session's audio to `<session id>.m4a` next to the history JSON; subscribes to `AudioHub`, sums sources on a 250 ms tick |
| `Sources/Models.swift` | settings (`UserDefaults` key `polytranslate.settings.v1`), `LanguageCatalog` |
| `Resources/Info.plist` | permission usage strings, bundle ID `dev.samliao.polytranslatelive` |
| `tools/make_icon.swift` | regenerates the icon (no SF Symbols — Apple's license forbids them in icons) |
| `tools/make_cert.sh` | creates the self-signed “PolyTranslate Live Dev” certificate so `build.sh` signs with a stable identity |
| `~/Library/Application Support/PolyTranslateLive/history/` | saved sessions, one JSON each, plus the session's `.m4a` recording when recording is on (default on; Settings › Recording) |
| `~/Documents/PolyTranslate Live/` | Markdown transcripts, only if the user enables it in Settings (off by default) |

## Conventions when modifying

- Keep it buildable with plain `swiftc` (see `build.sh`); do not introduce an Xcode project or SwiftPM
  dependencies unless asked.
- Swift language mode is 5 (`-swift-version 5`); concurrency warnings are tolerated, errors are not.
- All user-visible text goes through `tr("key")` / `trf("key", args)` with entries for both languages.
- Chinese UI text uses Taiwan wording (繁體中文、台灣用語). Every key needs all four languages; `tr()` falls back to English if one is missing.
- Never log recognized text or translations with `dlog(...)`; use `dlogv(...)` so it stays out of the log unless verbose.
- After changes, run `./build.sh test`, then `./build.sh` and the test-mode check above.
