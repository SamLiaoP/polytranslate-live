import Foundation

/// 介面語言。
enum UILanguage: String, Codable, CaseIterable, Identifiable {
    case en = "en"
    case zhHant = "zh-Hant"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .en: return "English"
        case .zhHant: return "繁體中文"
        }
    }
}

/// 字串表。`tr("key")` 取字串，`trf("key", args…)` 帶格式。
enum L10n {
    nonisolated(unsafe) static var language: UILanguage = .en

    static func t(_ key: String) -> String {
        guard let entry = table[key] else { return key }
        return language == .en ? entry.0 : entry.1
    }

    /// (English, 繁體中文)
    private static let table: [String: (String, String)] = [
        "app.title": ("PolyTranslate Live", "多語即譯"),
        "start": ("Start", "開始"),
        "stop": ("Stop", "停止"),
        "start.help": ("Start (⌘ Space)", "開始（⌘空白鍵）"),
        "stop.help": ("Stop (⌘ Space)", "停止（⌘空白鍵）"),
        "settings": ("Settings", "設定"),
        "translate.to": ("Translate to", "翻譯成"),
        "audio.source": ("Audio source", "聲音來源"),
        "pane.add": ("Add language pane", "新增語言欄"),
        "pane.add.max": ("Up to %d panes", "最多 %d 欄"),
        "pane.add.help": ("Add a pane that listens for another language", "再加一欄，聽另一種語言"),
        "pack.download": ("Download language pack", "下載語言包"),
        "pack.ready": ("Language pack ready. Offline translation starts with the next sentence.", "語言包已就緒，下一句開始會用離線翻譯。"),
        "pack.failed": ("Download cancelled or failed: %@", "下載取消或失敗：%@"),
        "pane.transcriptOnly": ("Transcript only", "只顯示原文"),
        "pane.title.transcriptOnly": ("%@ (transcript only)", "%@（只顯示原文）"),
        "pane.clear": ("Clear this pane", "清除這一欄的字幕"),
        "pane.close": ("Close this pane", "關閉這一欄"),
        "empty.listening": ("Listening. %@ speech will show up here.", "聆聽中，聽到%@就會顯示在這裡"),
        "empty.idle": ("Press Start. %@ speech will show up here.", "按下「開始」後，聽到的%@會顯示在這裡"),
        "empty.hint": ("Original on top, %@ translation below", "原文在上，%@譯文在下"),
        "line.failed": ("Translation failed", "翻譯失敗"),
        "line.translating": ("Translating", "翻譯中"),
        "settings.ui": ("Interface language", "介面語言"),
        "settings.subtitles": ("Subtitles", "字幕"),
        "settings.fontSize": ("Font size", "字級"),
        "settings.sample": ("Sample subtitle 範例字幕", "範例字幕 Sample subtitle"),
        "settings.translation": ("Translation", "翻譯"),
        "settings.drafts": ("Translate sentences while they are still being spoken (draft translation)", "還沒說完的句子也先翻譯（草稿翻譯）"),
        "settings.translation.note": ("Translation uses the translator built into macOS and runs entirely on this Mac. Installing the offline language packs gives the fastest results; without them, online translation is used automatically.",
                                      "翻譯使用 macOS 內建的翻譯功能，全程在這台 Mac 上處理。安裝離線語言包後速度最快，沒有安裝時會自動改用線上翻譯。"),
        "settings.openRegion": ("Open Language & Region settings", "打開「語言與地區」設定"),
        "settings.transcript": ("Transcript", "逐字稿"),
        "settings.saveTranscript": ("Save the transcript to Documents › %@ when stopping", "停止時把逐字稿存到「文件 › %@」"),
        "done": ("Done", "完成"),
        "status.listening": ("Listening", "聆聽中"),
        "status.preparing": ("Preparing", "準備中"),
        "status.stopped": ("Stopped", "已停止"),
        "status.downloading": ("Downloading %@ speech model…", "下載%@語音模型…"),
        "source.system": ("System audio", "系統聲音"),
        "source.mic": ("Microphone", "麥克風"),
        "source.mixed": ("Mixed (system audio + microphone)", "混合（系統聲音＋麥克風）"),
        "source.mixed.short": ("Mixed", "混合輸入"),
        "hint.online": ("Using online translation (about 0.3–1 s). Install the offline language pack to get under 0.1 s: press “Download language pack”, or go to System Settings › General › Language & Region › Translation Languages.",
                        "目前使用線上翻譯（約 0.3 到 1 秒）。安裝離線語言包可以縮到 0.1 秒以內：按「下載語言包」，或到「系統設定 › 一般 › 語言與地區 › 翻譯語言」。"),
        "err.noDisplay": ("No display found; cannot capture system audio.", "找不到螢幕，無法擷取系統聲音。"),
        "err.noMic": ("No microphone available.", "找不到可用的麥克風。"),
        "err.micDenied": ("Microphone access was denied. Allow it in System Settings › Privacy & Security › Microphone.", "麥克風權限被拒絕。請到 系統設定 › 隱私權與安全性 › 麥克風 開啟。"),
        "err.screenDenied": ("Cannot capture system audio (%@). Allow “PolyTranslate Live” in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch the app.",
                             "無法擷取系統聲音（%@）。請到 系統設定 › 隱私權與安全性 › 螢幕與系統音訊錄製 允許「多語即譯」，然後重新啟動 App。"),
        "err.systemAudioInterrupted": ("System audio capture stopped: %@", "系統聲音擷取中斷：%@"),
        "err.unsupportedLocale": ("Speech recognition on this Mac does not support %@.", "這台 Mac 的語音辨識不支援 %@。"),
        "err.noAudioFormat": ("The speech model does not accept the current audio format.", "語音辨識模型不接受目前的音訊格式。"),
        "err.modelDownload": ("Failed to download the speech model: %@", "下載語音模型失敗：%@"),
        "err.packMissing": ("Cannot translate %@ → %@: press “Download language pack”, or install both languages in System Settings › General › Language & Region › Translation Languages.",
                            "無法翻譯 %@ → %@：請按「下載語言包」，或到 系統設定 › 一般 › 語言與地區 › 翻譯語言 安裝這兩種語言。"),
        "err.unsupportedPair": ("The built-in translator does not support %@ → %@.", "系統內建翻譯不支援 %@ → %@ 這個組合。"),
        "err.llmNotConfigured": ("The external language model is not configured.", "尚未設定外部語言模型。"),
        "err.llmHTTP": ("The external language model returned an error (%d): %@", "外部語言模型回應錯誤（%d）：%@"),
        "err.llmBadResponse": ("Unexpected response from the external language model.", "外部語言模型回應格式不符。"),
        "err.noLane": ("Speech recognition could not start.\n%@", "語音辨識無法啟動。\n%@"),
        "menu.about": ("About PolyTranslate Live", "關於 多語即譯"),
        "menu.settings": ("Settings…", "設定…"),
        "menu.hide": ("Hide PolyTranslate Live", "隱藏 多語即譯"),
        "menu.quit": ("Quit PolyTranslate Live", "結束 多語即譯"),
        "menu.edit": ("Edit", "編輯"),
        "menu.undo": ("Undo", "復原"),
        "menu.redo": ("Redo", "重做"),
        "menu.cut": ("Cut", "剪下"),
        "menu.copy": ("Copy", "拷貝"),
        "menu.paste": ("Paste", "貼上"),
        "menu.selectAll": ("Select All", "全選"),
        "menu.window": ("Window", "視窗"),
        "menu.minimize": ("Minimize", "縮到最小"),
        "menu.close": ("Close", "關閉"),
        "transcript.folder": ("PolyTranslate Live", "多語即譯"),
        "transcript.title": ("# PolyTranslate Live transcript %@", "# 多語即譯逐字稿 %@"),
        "transcript.meta": ("Source: %@　Translate to: %@", "來源：%@　翻譯成：%@"),
        "lang.paren": (" (%@)", "（%@）"),
        "history": ("History", "歷史紀錄"),
        "history.toggle": ("Show or hide history", "顯示或收起歷史紀錄"),
        "history.empty": ("No recordings yet.\nEach session is saved here when you press Stop.", "還沒有紀錄。\n每次按「停止」後，這一段會存在這裡。"),
        "history.lines": ("%d lines", "%d 句"),
        "history.delete": ("Delete", "刪除"),
        "history.copy": ("Copy as text", "複製成文字"),
        "history.back": ("Back to live", "回到即時字幕"),
        "history.live": ("Live", "即時"),
        "history.viewing": ("Viewing a past recording", "正在查看過去的紀錄"),
        // 語言名稱（介面語言的說法）
        "lang.zh-Hant": ("Traditional Chinese", "繁體中文"),
        "lang.zh-Hans": ("Simplified Chinese", "簡體中文"),
        "lang.yue": ("Cantonese", "粵語"),
        "lang.en": ("English", "英文"),
        "lang.en-GB": ("English (UK)", "英文（英國）"),
        "lang.ja": ("Japanese", "日文"),
        "lang.ko": ("Korean", "韓文"),
        "lang.fr": ("French", "法文"),
        "lang.de": ("German", "德文"),
        "lang.es": ("Spanish", "西班牙文"),
        "lang.pt-BR": ("Portuguese (Brazil)", "葡萄牙文（巴西）"),
        "lang.it": ("Italian", "義大利文"),
    ]
}

func tr(_ key: String) -> String { L10n.t(key) }

func trf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.t(key), arguments: args)
}
