import Foundation

/// 介面語言。
enum UILanguage: String, Codable, CaseIterable, Identifiable {
    case en = "en"
    case zhHant = "zh-Hant"
    case ja = "ja"
    case ko = "ko"

    var id: String { rawValue }
    /// 選單上用該語言自己的寫法。
    var label: String {
        switch self {
        case .en: return "English"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }
    /// 日期格式與系統語言名稱用的 locale。
    var localeIdentifier: String {
        switch self {
        case .en: return "en_US"
        case .zhHant: return "zh_TW"
        case .ja: return "ja_JP"
        case .ko: return "ko_KR"
        }
    }
    /// 在 `table` 陣列裡的位置。
    fileprivate var index: Int {
        switch self {
        case .en: return 0
        case .zhHant: return 1
        case .ja: return 2
        case .ko: return 3
        }
    }
}

/// 字串表。`tr("key")` 取字串，`trf("key", args…)` 帶格式。
enum L10n {
    /// 主執行緒寫、背景執行緒（辨識通道的狀態訊息、擷取錯誤）讀，所以用鎖保護。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _language: UILanguage = .en
    static var language: UILanguage {
        get { lock.withLock { _language } }
        set { lock.withLock { _language = newValue } }
    }

    static func t(_ key: String) -> String {
        guard let entry = table[key], let en = entry.first else { return key }
        let i = language.index
        return i < entry.count ? entry[i] : en
    }

    /// 測試用：回傳沒有湊齊所有介面語言的 key。
    static func incompleteKeys() -> [String] {
        table.filter { $0.value.count != UILanguage.allCases.count }.map(\.key).sorted()
    }

    /// 每個 key 四個字串，順序固定：English、繁體中文、日本語、한국어。少了就退回英文。
    private static let table: [String: [String]] = [
        "app.title": ["PolyTranslate Live", "多語即譯", "PolyTranslate Live", "PolyTranslate Live"],
        "start": ["Start", "開始", "開始", "시작"],
        "stop": ["Stop", "停止", "停止", "정지"],
        "start.help": ["Start (⌘ Space)", "開始（⌘空白鍵）", "開始（⌘スペース）", "시작 (⌘ Space)"],
        "stop.help": ["Stop (⌘ Space)", "停止（⌘空白鍵）", "停止（⌘スペース）", "정지 (⌘ Space)"],
        "settings": ["Settings", "設定", "設定", "설정"],
        "options": ["Options", "選項", "オプション", "옵션"],
        "scroll.latest": ["Back to latest", "回到最新", "最新へ戻る", "최신으로 이동"],
        "translate.to": ["Translate to", "翻譯成", "翻訳先", "번역 언어"],
        "audio.source": ["Audio source", "聲音來源", "音声ソース", "오디오 소스"],
        "pane.add": ["Add language pane", "新增語言欄", "言語パネルを追加", "언어 패널 추가"],
        "pane.add.max": ["Up to %d panes", "最多 %d 欄", "最大 %d パネル", "최대 %d개 패널"],
        "pane.add.help": ["Add a pane that listens for another language", "再加一欄，聽另一種語言", "別の言語を聞き取るパネルを追加", "다른 언어를 듣는 패널 추가"],
        "pack.download": ["Download language pack", "下載語言包", "言語パックをダウンロード", "언어 팩 다운로드"],
        "pack.ready": ["Language pack ready. Offline translation starts with the next sentence.",
                       "語言包已就緒，下一句開始會用離線翻譯。",
                       "言語パックの準備ができました。次の文からオフライン翻訳になります。",
                       "언어 팩이 준비되었습니다. 다음 문장부터 오프라인 번역을 사용합니다."],
        "pack.failed": ["Download cancelled or failed: %@", "下載取消或失敗：%@", "ダウンロードが中止または失敗しました：%@", "다운로드가 취소되었거나 실패했습니다: %@"],
        "pane.transcriptOnly": ["Transcript only", "只顯示原文", "原文のみ", "원문만 표시"],
        "pane.title.transcriptOnly": ["%@ (transcript only)", "%@（只顯示原文）", "%@（原文のみ）", "%@ (원문만)"],
        "pane.clear": ["Clear this pane", "清除這一欄的字幕", "このパネルの字幕を消去", "이 패널의 자막 지우기"],
        "pane.close": ["Close this pane", "關閉這一欄", "このパネルを閉じる", "이 패널 닫기"],
        "empty.listening": ["Listening. %@ speech will show up here.", "聆聽中，聽到%@就會顯示在這裡", "聞き取り中。%@の音声がここに表示されます。", "듣는 중입니다. %@ 음성이 여기에 표시됩니다."],
        "empty.idle": ["Press Start. %@ speech will show up here.", "按下「開始」後，聽到的%@會顯示在這裡", "「開始」を押すと、%@の音声がここに表示されます。", "'시작'을 누르면 %@ 음성이 여기에 표시됩니다."],
        "empty.hint": ["Original on top, %@ translation below", "原文在上，%@譯文在下", "上が原文、下が%@訳", "위는 원문, 아래는 %@ 번역"],
        "line.failed": ["Translation failed", "翻譯失敗", "翻訳に失敗しました", "번역 실패"],
        "line.translating": ["Translating", "翻譯中", "翻訳中", "번역 중"],
        "settings.ui": ["Interface language", "介面語言", "表示言語", "인터페이스 언어"],
        "settings.subtitles": ["Subtitles", "字幕", "字幕", "자막"],
        "settings.fontSize": ["Font size", "字級", "文字サイズ", "글자 크기"],
        "settings.sample": ["Sample subtitle 範例字幕", "範例字幕 Sample subtitle", "字幕のサンプル Sample subtitle", "자막 예시 Sample subtitle"],
        "settings.translation": ["Translation", "翻譯", "翻訳", "번역"],
        "settings.drafts": ["Translate sentences while they are still being spoken (draft translation)",
                            "還沒說完的句子也先翻譯（草稿翻譯）",
                            "話し終える前の文も先に翻訳する（下書き翻訳）",
                            "아직 말하는 중인 문장도 미리 번역 (초안 번역)"],
        "settings.translation.note": ["Translation uses the translator built into macOS and runs entirely on this Mac. Installing the offline language packs gives the fastest results; without them, online translation is used automatically.",
                                      "翻譯使用 macOS 內建的翻譯功能，全程在這台 Mac 上處理。安裝離線語言包後速度最快，沒有安裝時會自動改用線上翻譯。",
                                      "翻訳には macOS 内蔵の翻訳機能を使い、すべてこの Mac 上で処理します。オフライン言語パックをインストールすると最も速くなります。未インストールの場合は自動的にオンライン翻訳を使います。",
                                      "번역은 macOS에 내장된 번역 기능을 사용하며 모두 이 Mac에서 처리됩니다. 오프라인 언어 팩을 설치하면 가장 빠릅니다. 설치되어 있지 않으면 자동으로 온라인 번역을 사용합니다."],
        "settings.openRegion": ["Open Language & Region settings", "打開「語言與地區」設定", "「言語と地域」設定を開く", "'언어 및 지역' 설정 열기"],
        "settings.transcript": ["Transcript", "逐字稿", "文字起こし", "녹취록"],
        "settings.saveTranscript": ["Save the transcript to Documents › %@ when stopping", "停止時把逐字稿存到「文件 › %@」", "停止時に文字起こしを「書類 › %@」に保存", "정지할 때 녹취록을 '문서 › %@'에 저장"],
        "done": ["Done", "完成", "完了", "완료"],
        "settings.recognition": ["Recognition", "辨識", "音声認識", "음성 인식"],
        "settings.listenTarget": ["Someone will speak the target language (recognize it and skip it)",
                                  "有人會講目標語言（辨識到就略過，不顯示）",
                                  "ターゲット言語を話す人がいる（認識したら表示せずスキップ）",
                                  "대상 언어를 말하는 사람이 있음 (인식하면 표시하지 않고 건너뜀)"],
        "settings.listenTarget.help": ["Off: only the languages of your panes are recognized and nothing is dropped. On: an extra recognizer listens for the target language so it is not mangled into another pane, at the cost of occasionally dropping a sentence.",
                                       "關：只辨識各欄選的語言，不會丟句子。開：多開一條目標語言的辨識，有人講目標語言時不會被拼成別欄的亂碼，但偶爾會誤丟一句。",
                                       "オフ：各パネルの言語だけを認識し、文が落ちることはありません。オン：ターゲット言語用の認識器を追加し、他のパネルに文字化けして表示されるのを防ぎますが、まれに文が落ちます。",
                                       "끔: 각 패널의 언어만 인식하며 문장이 빠지지 않습니다. 켬: 대상 언어 인식기를 추가해 다른 패널에 엉뚱하게 표시되는 것을 막지만 가끔 문장이 빠질 수 있습니다."],
        "settings.vocabulary": ["Vocabulary (one term per line)", "辨識詞彙表（一行一個）", "語彙（1 行に 1 語）", "어휘 목록 (한 줄에 하나)"],
        "settings.vocabulary.help": ["Names, products and jargon the recognizer should prefer, e.g. OpenAI, Codex, Cathay. Applies to every pane from the next session.",
                                     "人名、產品名、專有名詞，讓辨識器偏向這些拼法，例如 OpenAI、Codex、Cathay。下一場開始對所有欄位生效。",
                                     "認識器に優先させたい人名・製品名・専門用語（例：OpenAI、Codex、Cathay）。次のセッションからすべてのパネルに適用されます。",
                                     "인식기가 우선하도록 할 이름, 제품명, 전문 용어 (예: OpenAI, Codex, Cathay). 다음 세션부터 모든 패널에 적용됩니다."],
        "settings.wording": ["Chinese wording", "中文用語", "中国語の用語", "중국어 용어"],
        "settings.taiwanWording": ["Convert Traditional Chinese translations to Taiwan wording (built-in OpenCC table, e.g. 軟件→軟體, 信息→資訊)",
                                   "繁體中文譯文自動換成台灣用語（內建 OpenCC 對照表，例如 軟件→軟體、信息→資訊）",
                                   "繁体字中国語の訳文を台湾の用語に変換（内蔵の OpenCC 対照表、例：軟件→軟體、信息→資訊）",
                                   "중국어(번체) 번역을 대만 용어로 변환 (내장 OpenCC 표, 예: 軟件→軟體, 信息→資訊)"],
        "settings.wordingRules": ["Extra replacements (one per line: original=replacement)", "自訂替換（一行一條：原詞=替換）", "追加の置換（1 行に 1 つ：元の語=置換後）", "추가 치환 (한 줄에 하나: 원래 단어=바꿀 단어)"],
        "settings.wordingRules.help": ["Applied before the built-in table, so you can override it. Works for Traditional Chinese targets only.",
                                       "先於內建表套用，可以覆蓋它。只對目標語言是繁體中文時生效。",
                                       "内蔵表より先に適用されるため、上書きできます。ターゲットが繁体字中国語のときのみ有効です。",
                                       "내장 표보다 먼저 적용되므로 덮어쓸 수 있습니다. 대상 언어가 중국어(번체)일 때만 적용됩니다."],
        "settings.recording": ["Recording", "錄音", "録音", "녹음"],
        "settings.recordAudio": ["Record audio during sessions", "翻譯時同時完整錄音", "セッション中に音声を録音する", "세션 중 오디오 녹음"],
        "settings.recording.note": ["Recordings are kept with the history in Application Support (AAC, 16 kHz mono, about 15 MB per hour) and are deleted together with their history entry. Use “Save recording…” in History to export one.",
                                    "錄音和歷史紀錄一起存在 Application Support（AAC、16 kHz 單聲道，每小時約 15 MB），刪除該筆紀錄時會一起刪除。要匯出請在歷史紀錄裡按「儲存錄音…」。",
                                    "録音は履歴と一緒に Application Support に保存されます（AAC、16 kHz モノラル、1 時間あたり約 15 MB）。履歴を削除すると録音も削除されます。書き出すには履歴で「録音を保存…」を押してください。",
                                    "녹음은 기록과 함께 Application Support에 저장되며(AAC, 16 kHz 모노, 시간당 약 15 MB) 해당 기록을 삭제하면 함께 삭제됩니다. 내보내려면 기록에서 '녹음 저장…'을 누르세요."],
        "recording.save": ["Save recording…", "儲存錄音…", "録音を保存…", "녹음 저장…"],
        "recording.reveal": ["Show recording in Finder", "在 Finder 中顯示錄音", "録音を Finder に表示", "Finder에서 녹음 보기"],
        "recording.badge": ["REC", "REC", "REC", "REC"],
        "recording.badge.help": ["Recording audio", "錄音中", "録音中", "녹음 중"],
        "err.recordingStart": ["Could not start recording: %@", "無法開始錄音：%@", "録音を開始できませんでした：%@", "녹음을 시작할 수 없습니다: %@"],
        "err.recordingSave": ["Could not save the recording: %@", "錄音存檔失敗：%@", "録音を保存できませんでした：%@", "녹음을 저장하지 못했습니다: %@"],
        "status.listening": ["Listening", "聆聽中", "聞き取り中", "듣는 중"],
        "status.preparing": ["Preparing", "準備中", "準備中", "준비 중"],
        "status.stopped": ["Stopped", "已停止", "停止中", "정지됨"],
        "status.downloading": ["Downloading %@ speech model…", "下載%@語音模型…", "%@の音声モデルをダウンロード中…", "%@ 음성 모델 다운로드 중…"],
        "source.system": ["System audio", "系統聲音", "システム音声", "시스템 오디오"],
        "source.mic": ["Microphone", "麥克風", "マイク", "마이크"],
        "source.mixed": ["Mixed (system audio + microphone)", "混合（系統聲音＋麥克風）", "ミックス（システム音声＋マイク）", "혼합 (시스템 오디오 + 마이크)"],
        "source.mixed.short": ["Mixed", "混合輸入", "ミックス", "혼합"],
        "hint.online": ["Using online translation (about 0.3–1 s). Install the offline language pack to get under 0.1 s: press “Download language pack”, or go to System Settings › General › Language & Region › Translation Languages.",
                        "目前使用線上翻譯（約 0.3 到 1 秒）。安裝離線語言包可以縮到 0.1 秒以內：按「下載語言包」，或到「系統設定 › 一般 › 語言與地區 › 翻譯語言」。",
                        "現在オンライン翻訳を使用しています（約 0.3〜1 秒）。オフライン言語パックをインストールすると 0.1 秒未満になります：「言語パックをダウンロード」を押すか、「システム設定 › 一般 › 言語と地域 › 翻訳言語」で追加してください。",
                        "현재 온라인 번역을 사용 중입니다 (약 0.3~1초). 오프라인 언어 팩을 설치하면 0.1초 이내로 줄어듭니다: '언어 팩 다운로드'를 누르거나 '시스템 설정 › 일반 › 언어 및 지역 › 번역 언어'에서 추가하세요."],
        "err.noDisplay": ["No display found; cannot capture system audio.", "找不到螢幕，無法擷取系統聲音。", "ディスプレイが見つからないため、システム音声を取得できません。", "디스플레이를 찾을 수 없어 시스템 오디오를 캡처할 수 없습니다."],
        "err.noMic": ["No microphone available.", "找不到可用的麥克風。", "使用できるマイクがありません。", "사용할 수 있는 마이크가 없습니다."],
        "err.micDenied": ["Microphone access was denied. Allow it in System Settings › Privacy & Security › Microphone.",
                          "麥克風權限被拒絕。請到 系統設定 › 隱私權與安全性 › 麥克風 開啟。",
                          "マイクへのアクセスが拒否されました。「システム設定 › プライバシーとセキュリティ › マイク」で許可してください。",
                          "마이크 접근이 거부되었습니다. '시스템 설정 › 개인정보 보호 및 보안 › 마이크'에서 허용하세요."],
        "err.screenDenied": ["Cannot capture system audio (%@). Allow “PolyTranslate Live” in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch the app. If the switch is already on, the app was probably rebuilt and macOS no longer matches the old permission: remove it with “−”, relaunch, and allow again.",
                             "無法擷取系統聲音（%@）。請到 系統設定 › 隱私權與安全性 › 螢幕與系統音訊錄製 允許「PolyTranslate Live」，然後重新啟動 App。如果開關已經是開的，通常是 App 重新編譯過、macOS 認不得舊的授權：用「−」把它移除，重新啟動 App 再允許一次。",
                             "システム音声を取得できません（%@）。「システム設定 › プライバシーとセキュリティ › 画面とシステムオーディオの収録」で「PolyTranslate Live」を許可し、App を再起動してください。スイッチがすでにオンの場合は、App が再ビルドされて以前の許可が無効になっています：「−」で削除し、App を再起動して再度許可してください。",
                             "시스템 오디오를 캡처할 수 없습니다 (%@). '시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음'에서 'PolyTranslate Live'를 허용한 뒤 앱을 다시 실행하세요. 스위치가 이미 켜져 있다면 앱이 다시 빌드되어 이전 허가가 무효가 된 것입니다: '−'로 제거하고 앱을 다시 실행한 뒤 다시 허용하세요."],
        "err.systemAudioInterrupted": ["System audio capture stopped: %@", "系統聲音擷取中斷：%@", "システム音声の取得が中断されました：%@", "시스템 오디오 캡처가 중단되었습니다: %@"],
        "err.unsupportedLocale": ["Speech recognition on this Mac does not support %@.", "這台 Mac 的語音辨識不支援 %@。", "この Mac の音声認識は %@ に対応していません。", "이 Mac의 음성 인식은 %@을(를) 지원하지 않습니다."],
        "err.noAudioFormat": ["The speech model does not accept the current audio format.", "語音辨識模型不接受目前的音訊格式。", "音声認識モデルが現在のオーディオ形式を受け付けません。", "음성 인식 모델이 현재 오디오 형식을 지원하지 않습니다."],
        "err.modelDownload": ["Failed to download the speech model: %@", "下載語音模型失敗：%@", "音声モデルのダウンロードに失敗しました：%@", "음성 모델 다운로드 실패: %@"],
        "err.packMissing": ["Cannot translate %@ → %@: press “Download language pack”, or install both languages in System Settings › General › Language & Region › Translation Languages.",
                            "無法翻譯 %@ → %@：請按「下載語言包」，或到 系統設定 › 一般 › 語言與地區 › 翻譯語言 安裝這兩種語言。",
                            "%@ → %@ を翻訳できません：「言語パックをダウンロード」を押すか、「システム設定 › 一般 › 言語と地域 › 翻訳言語」で両方の言語をインストールしてください。",
                            "%@ → %@ 번역을 할 수 없습니다: '언어 팩 다운로드'를 누르거나 '시스템 설정 › 일반 › 언어 및 지역 › 번역 언어'에서 두 언어를 설치하세요."],
        "err.unsupportedPair": ["The built-in translator does not support %@ → %@.", "系統內建翻譯不支援 %@ → %@ 這個組合。", "内蔵の翻訳機能は %@ → %@ に対応していません。", "내장 번역기는 %@ → %@ 조합을 지원하지 않습니다."],
        "err.noLane": ["Speech recognition could not start.\n%@", "語音辨識無法啟動。\n%@", "音声認識を開始できませんでした。\n%@", "음성 인식을 시작할 수 없습니다.\n%@"],
        "err.transcriptSave": ["Could not save the transcript: %@", "逐字稿存檔失敗：%@", "文字起こしを保存できませんでした：%@", "녹취록을 저장하지 못했습니다: %@"],
        "menu.about": ["About PolyTranslate Live", "關於 多語即譯", "PolyTranslate Live について", "PolyTranslate Live 정보"],
        "menu.settings": ["Settings…", "設定…", "設定…", "설정…"],
        "menu.hide": ["Hide PolyTranslate Live", "隱藏 多語即譯", "PolyTranslate Live を隠す", "PolyTranslate Live 가리기"],
        "menu.quit": ["Quit PolyTranslate Live", "結束 多語即譯", "PolyTranslate Live を終了", "PolyTranslate Live 종료"],
        "menu.edit": ["Edit", "編輯", "編集", "편집"],
        "menu.undo": ["Undo", "復原", "取り消す", "실행 취소"],
        "menu.redo": ["Redo", "重做", "やり直す", "실행 복귀"],
        "menu.cut": ["Cut", "剪下", "カット", "오려두기"],
        "menu.copy": ["Copy", "拷貝", "コピー", "복사"],
        "menu.paste": ["Paste", "貼上", "ペースト", "붙여넣기"],
        "menu.selectAll": ["Select All", "全選", "すべてを選択", "전체 선택"],
        "menu.window": ["Window", "視窗", "ウインドウ", "윈도우"],
        "menu.minimize": ["Minimize", "縮到最小", "しまう", "최소화"],
        "menu.close": ["Close", "關閉", "閉じる", "닫기"],
        // 四種介面語言同名，切語言不會分成多個資料夾
        "transcript.folder": ["PolyTranslate Live", "PolyTranslate Live", "PolyTranslate Live", "PolyTranslate Live"],
        "transcript.title": ["# PolyTranslate Live transcript %@", "# 多語即譯逐字稿 %@", "# PolyTranslate Live 文字起こし %@", "# PolyTranslate Live 녹취록 %@"],
        "transcript.meta": ["Source: %@　Translate to: %@", "來源：%@　翻譯成：%@", "ソース：%@　翻訳先：%@", "소스: %@　번역 언어: %@"],
        "lang.paren": [" (%@)", "（%@）", "（%@）", " (%@)"],
        "settings.arbiter": ["Language detection (advanced)", "語言判斷（進階）", "言語判定（詳細）", "언어 판별 (고급)"],
        "settings.arbiter.note": ["When several languages are recognized in parallel, each finished sentence is scored by the recognizer's confidence (0–1) and the highest wins. Measured on clean speech: correct language ≥ 0.65, wrong language 0.18–0.55. Real speech with accents or noise scores lower, so if correct sentences disappear, lower these values. Changes apply immediately. Decisions are logged in ~/Library/Logs/PolyTranslateLive.log (lines starting with “arbiter”).",
                                  "多種語言同時辨識時，每句定稿會用辨識器的信心值（0–1）比較，最高的勝出。乾淨語音實測：正確語言 ≥ 0.65，錯誤語言 0.18–0.55。真人口音或背景噪音會讓數字整體變低，如果正確的句子常常消失，就把這些值調低。調整立即生效。每次判斷都記錄在 ~/Library/Logs/PolyTranslateLive.log（開頭為「arbiter」的行）。",
                                  "複数の言語を同時に認識する場合、確定した各文を認識器の信頼度（0〜1）で比較し、最も高いものを採用します。クリアな音声での実測：正しい言語 ≥ 0.65、誤った言語 0.18〜0.55。訛りや雑音があると全体的に低くなるので、正しい文が消えることが多ければ値を下げてください。変更は即時に反映されます。判定は ~/Library/Logs/PolyTranslateLive.log（「arbiter」で始まる行）に記録されます。",
                                  "여러 언어를 동시에 인식할 때 완성된 각 문장을 인식기의 신뢰도(0~1)로 비교해 가장 높은 것을 채택합니다. 깨끗한 음성 기준 측정값: 올바른 언어 ≥ 0.65, 잘못된 언어 0.18~0.55. 억양이나 소음이 있으면 전체적으로 낮아지므로 올바른 문장이 자주 사라지면 값을 낮추세요. 변경은 즉시 적용됩니다. 판별 기록은 ~/Library/Logs/PolyTranslateLive.log('arbiter'로 시작하는 줄)에 남습니다."],
        "settings.arb.junk": ["Discard below", "低於此值直接丟棄", "この値未満は破棄", "이 값 미만은 버림"],
        "settings.arb.junk.help": ["Any result below this confidence is thrown away, even if it is the only one.", "不管有沒有別的候選，低於這個信心值的結果一律丟掉。", "他に候補がなくても、この信頼度未満の結果は破棄します。", "다른 후보가 없어도 이 신뢰도 미만의 결과는 버립니다."],
        "settings.arb.loneDrop": ["Single result: discard below", "只有一種語言有結果時，低於此值丟棄", "候補が 1 言語のみ：この値未満は破棄", "후보가 한 언어뿐일 때: 이 값 미만은 버림"],
        "settings.arb.loneDrop.help": ["When only one language produced a sentence, it is dropped below this value. Lower this if sentences go missing.", "只有一種語言辨識出這句話時，信心值低於此值就丟。句子常不見的話先降這個。", "1 つの言語だけが文を出した場合、この値未満なら破棄します。文が消えるなら下げてください。", "한 언어만 문장을 내놓았을 때 이 값 미만이면 버립니다. 문장이 사라지면 이 값을 낮추세요."],
        "settings.arb.loneStrict": ["Single result: extra checks below", "只有一種語言有結果時，低於此值要通過額外檢查", "候補が 1 言語のみ：この値未満は追加チェック", "후보가 한 언어뿐일 때: 이 값 미만은 추가 검사"],
        "settings.arb.loneStrict.help": ["Between the two thresholds the sentence must also match the language's writing system and be at least 2.5 s long.", "介於兩個門檻之間的句子，還要文字系統正確、長度至少 2.5 秒才放行。", "2 つのしきい値の間の文は、文字体系が一致し、長さが 2.5 秒以上の場合のみ通します。", "두 임계값 사이의 문장은 문자 체계가 맞고 길이가 2.5초 이상일 때만 통과합니다."],
        "settings.arb.fastPass": ["Trust the current language above", "目前語言高於此值就直接放行", "現在の言語がこの値を超えたら即採用", "현재 언어가 이 값을 넘으면 바로 채택"],
        "settings.arb.fastPass.help": ["If the language of the previous sentence scores above this, the result is shown at once without waiting about a second for the other languages.", "上一句的語言這次信心值高於此值，就不等其他語言約一秒，直接顯示。", "直前の文の言語がこの値を超えた場合、他の言語を約 1 秒待たずにすぐ表示します。", "직전 문장의 언어가 이 값을 넘으면 다른 언어를 약 1초 기다리지 않고 바로 표시합니다."],
        "settings.arb.bonus": ["Bonus for the current language", "偏向目前語言的加分", "現在の言語への加点", "현재 언어 가산점"],
        "settings.arb.bonus.help": ["Added to the previous sentence's language when comparing. Too high and real language switches get suppressed.", "比較時加給上一句語言的分數。太高會壓住真正的語言切換。", "比較時に直前の文の言語に加えます。高すぎると実際の言語切り替えが抑えられます。", "비교할 때 직전 문장의 언어에 더합니다. 너무 높으면 실제 언어 전환이 억제됩니다."],
        "settings.arb.reset": ["Reset to defaults", "重設為預設值", "デフォルトに戻す", "기본값으로 재설정"],
        "history": ["History", "歷史紀錄", "履歴", "기록"],
        "history.toggle": ["Show or hide history", "顯示或收起歷史紀錄", "履歴を表示／非表示", "기록 보기/숨기기"],
        "history.empty": ["No recordings yet.\nEach session is saved here when you press Stop.", "還沒有紀錄。\n每次按「停止」後，這一段會存在這裡。", "まだ記録がありません。\n「停止」を押すたびに、そのセッションがここに保存されます。", "아직 기록이 없습니다.\n'정지'를 누를 때마다 세션이 여기에 저장됩니다."],
        "history.lines": ["%d lines", "%d 句", "%d 文", "%d개 문장"],
        "history.delete": ["Delete", "刪除", "削除", "삭제"],
        "history.delete.confirm": ["Delete this recording?", "要刪除這筆紀錄嗎？", "この記録を削除しますか？", "이 기록을 삭제하시겠습니까?"],
        "history.delete.note": ["This cannot be undone.", "刪除後無法復原。", "この操作は取り消せません。", "이 작업은 되돌릴 수 없습니다."],
        "cancel": ["Cancel", "取消", "キャンセル", "취소"],
        "history.copy": ["Copy as text", "複製成文字", "テキストとしてコピー", "텍스트로 복사"],
        "history.back": ["Back to live", "回到即時字幕", "ライブに戻る", "실시간으로 돌아가기"],
        "history.live": ["Live", "即時", "ライブ", "실시간"],
        "history.viewing": ["Viewing a past recording", "正在查看過去的紀錄", "過去の記録を表示中", "지난 기록 보는 중"],
        "history.interrupted.short": ["Did not stop normally", "沒有正常停止", "正常に停止されませんでした", "정상 정지되지 않음"],
        "history.interrupted": ["This session did not stop normally (the app quit unexpectedly). Content is kept up to %@.", "這場沒有正常停止（程式異常結束），內容保留到 %@。", "このセッションは正常に停止されませんでした（アプリが異常終了）。%@ までの内容を保存しています。", "이 세션은 정상적으로 정지되지 않았습니다(앱 비정상 종료). %@까지의 내용이 저장되어 있습니다."],
        // 語言名稱（介面語言的說法）
        "lang.zh-Hant": ["Traditional Chinese", "繁體中文", "繁体字中国語", "중국어(번체)"],
        "lang.zh-Hans": ["Simplified Chinese", "簡體中文", "簡体字中国語", "중국어(간체)"],
        "lang.yue": ["Cantonese", "粵語", "広東語", "광둥어"],
        "lang.en": ["English", "英文", "英語", "영어"],
        "lang.en-GB": ["English (UK)", "英文（英國）", "英語（イギリス）", "영어(영국)"],
        "lang.ja": ["Japanese", "日文", "日本語", "일본어"],
        "lang.ko": ["Korean", "韓文", "韓国語", "한국어"],
        "lang.fr": ["French", "法文", "フランス語", "프랑스어"],
        "lang.de": ["German", "德文", "ドイツ語", "독일어"],
        "lang.es": ["Spanish", "西班牙文", "スペイン語", "스페인어"],
        "lang.pt-BR": ["Portuguese (Brazil)", "葡萄牙文（巴西）", "ポルトガル語（ブラジル）", "포르투갈어(브라질)"],
        "lang.it": ["Italian", "義大利文", "イタリア語", "이탈리아어"],
    ]
}

func tr(_ key: String) -> String { L10n.t(key) }

func trf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.t(key), arguments: args)
}
