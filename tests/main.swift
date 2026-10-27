// 純邏輯的單元測試：ScriptDetector、Arbiter、LanguageMap。
// 不用 XCTest（Command Line Tools 不一定有），一個小的斷言框架就夠。
//   ./build.sh test
import Accelerate
import AVFoundation
import CoreMedia
import Foundation

var failures = 0
var total = 0

func check(_ cond: Bool, _ name: String, file: String = #file, line: Int = #line) {
    total += 1
    if !cond {
        failures += 1
        print("✗ \(name)  (\(file.split(separator: "/").last ?? ""):\(line))")
    }
}
func checkEqual<T: Equatable>(_ a: T, _ b: T, _ name: String, file: String = #file, line: Int = #line) {
    total += 1
    if a != b {
        failures += 1
        print("✗ \(name): got \(a), expected \(b)  (\(file.split(separator: "/").last ?? ""):\(line))")
    }
}

let zh = LanguageCatalog.language("zh-Hant")
let en = LanguageCatalog.language("en")
let ja = LanguageCatalog.language("ja")
let ko = LanguageCatalog.language("ko")

func range(_ start: Double, _ end: Double) -> CMTimeRange {
    CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000), end: CMTime(seconds: end, preferredTimescale: 1000))
}
func seg(_ text: String, _ s: Double, _ e: Double, conf: Double = 0.9) -> SpeechSegment {
    SpeechSegment(text: text, range: range(s, e), confidence: conf)
}

// MARK: ScriptDetector

checkEqual(ScriptDetector.dominantScript("大家早安"), .han, "dominant han")
checkEqual(ScriptDetector.dominantScript("Good morning"), .latin, "dominant latin")
checkEqual(ScriptDetector.dominantScript("皆さんおはよう"), .kana, "dominant kana (日文漢字+假名)")
checkEqual(ScriptDetector.dominantScript("안녕하세요"), .hangul, "dominant hangul")
checkEqual(ScriptDetector.dominantScript(", , , ,"), .other, "dominant other (只有標點)")

check(ScriptDetector.scriptMatches("ビュー the Cordely Reselt", ja) == false, "日文通道吐出大半拉丁字母 → 不符")
check(ScriptDetector.scriptMatches("皆さん、おはようございます", ja), "日文假名 → 符")
check(ScriptDetector.scriptMatches("今天天氣很好", zh), "中文 → 符")
check(ScriptDetector.scriptMatches("今天てんき", zh) == false, "中文通道出現假名 → 不符")
check(ScriptDetector.scriptMatches("Hello world", en), "英文 → 符")
check(ScriptDetector.scriptMatches("1234", en), "只有數字 → 視為符合")

checkEqual(ScriptDetector.trimLeadingMismatch("...until thend.大家早安", zh), "大家早安", "中文草稿剪掉前面黏的英文")
checkEqual(ScriptDetector.trimLeadingMismatch("2024年營收成長", zh), "2024年營收成長", "開頭數字不能剪（中文）")
checkEqual(ScriptDetector.trimLeadingMismatch("3 people came", en), "3 people came", "開頭數字不能剪（英文）")
checkEqual(ScriptDetector.trimLeadingMismatch("大家好 hello there", en), "hello there", "英文草稿剪掉前面的中文")
checkEqual(ScriptDetector.trimLeadingMismatch("大家好", en), "", "整段都不是英文 → 空字串（不顯示）")

check(ScriptDetector.segmentFits("and.", zh) == false, "中文通道的英文碎片不合")
check(ScriptDetector.segmentFits("，", zh), "只有標點 → 寬鬆放行")
check(ScriptDetector.segmentFits("東京", ja), "日文漢字段落合")

// MARK: LanguageMap

checkEqual(LanguageMap.translationLanguage(forSpeechLocale: "zh_TW"), "zh-Hant", "zh_TW → zh-Hant")
checkEqual(LanguageMap.translationLanguage(forSpeechLocale: "zh_HK"), "zh-Hant", "zh_HK（不在目錄）→ zh-Hant")
checkEqual(LanguageMap.translationLanguage(forSpeechLocale: "zh_CN"), "zh-Hans", "zh_CN → zh-Hans")
checkEqual(LanguageMap.translationLanguage(forSpeechLocale: "pt_BR"), "pt-BR", "pt_BR → pt-BR")
checkEqual(LanguageMap.translationLanguage(forSpeechLocale: "nl_NL"), "nl", "未知 locale → 前兩碼")
checkEqual(en.speechBCP47, "en-US", "speechBCP47")
checkEqual(zh.speechBCP47, "zh-TW", "speechBCP47 zh")

// MARK: Arbiter（@MainActor）

MainActor.assumeIsolated {
    @MainActor func makeArbiter(_ langs: [Language]) -> (Arbiter, () -> [(Int, String)]) {
        let a = Arbiter(languages: langs)
        var out: [(Int, String)] = []
        a.onEmit = { out.append(($0, $1)) }
        return (a, { out })
    }

    // 1. 兩種語言對同一段音訊都交出定稿 → 信心高的贏，另一個丟掉。
    do {
        let (a, out) = makeArbiter([en, zh])
        a.receive(.init(slot: 1, text: "股的貓您", confidence: 0.40, range: range(0, 2), segments: []))
        a.receive(.init(slot: 0, text: "Good morning", confidence: 0.87, range: range(0, 2), segments: []))
        checkEqual(out().count, 1, "兩路齊 → 只放行一句")
        checkEqual(out().first?.0, 0, "英文信心高 → 英文贏")
        checkEqual(a.pendingCount, 0, "決定後沒有待處理")
    }

    // 2. 低於 junk 門檻直接丟，連群組都不建。
    do {
        let (a, out) = makeArbiter([en, zh])
        a.receive(.init(slot: 1, text: ", , , ,", confidence: 0.01, range: range(0, 2), segments: []))
        checkEqual(out().count, 0, "junk 不放行")
        checkEqual(a.pendingCount, 0, "junk 不建群組")
    }

    // 3. 只有一路交結果時會等計時器；flush() 要能立刻結算（停止時最後一句靠這個）。
    do {
        let (a, out) = makeArbiter([en, zh])
        a.receive(.init(slot: 0, text: "Thanks everyone, see you next week", confidence: 0.85, range: range(10, 14), segments: []))
        checkEqual(out().count, 0, "單一候選先等")
        checkEqual(a.pendingCount, 1, "有一句待處理")
        a.flush()
        checkEqual(out().count, 1, "flush 後放行")
        checkEqual(out().first?.1, "Thanks everyone, see you next week", "flush 放行的是那一句")
        checkEqual(a.pendingCount, 0, "flush 後清空")
    }

    // 4. 單一候選、信心低又短 → 當作錯誤語言的碎片丟掉。
    do {
        let (a, out) = makeArbiter([en, zh, ja])
        a.receive(.init(slot: 1, text: "註話", confidence: 0.50, range: range(0, 1), segments: []))
        a.flush()
        checkEqual(out().count, 0, "lone-low 短碎片丟掉")
    }

    // 5. 上一句是英文、這句英文信心很高 → 直通不等。
    do {
        let (a, out) = makeArbiter([en, zh])
        a.receive(.init(slot: 0, text: "First sentence here", confidence: 0.9, range: range(0, 2), segments: []))
        a.receive(.init(slot: 1, text: "亂碼", confidence: 0.3, range: range(0, 2), segments: []))
        checkEqual(out().count, 1, "第一句決定")
        a.receive(.init(slot: 0, text: "Second sentence", confidence: 0.95, range: range(3, 5), segments: []))
        checkEqual(out().count, 2, "偏好語言 + 高信心 → 直通")
        checkEqual(a.pendingCount, 0, "直通不留群組")
    }

    // 6. 已放行的音訊再出現在另一路的長定稿裡 → 只留沒放行過的段落，開頭的英文碎片也剪掉。
    do {
        let (a, out) = makeArbiter([en, zh])
        a.receive(.init(slot: 0, text: "until the end.", confidence: 0.9, range: range(0, 2), segments: []))
        a.receive(.init(slot: 1, text: "x", confidence: 0.3, range: range(0, 2), segments: []))
        checkEqual(out().count, 1, "英文先放行")
        a.receive(.init(slot: 1, text: "and.大家早安", confidence: 0.8, range: range(0, 5),
                        segments: [seg("and.", 0, 2), seg("大家早安", 2.5, 5)]))
        a.receive(.init(slot: 0, text: "da jia zao an", confidence: 0.3, range: range(2.5, 5), segments: []))
        checkEqual(out().count, 2, "中文句放行")
        checkEqual(out().last?.1, "大家早安", "被蓋住的英文段落剪掉，只留中文")
    }

    // 7. 單一語言（只顯示原文）→ 直接放行。
    do {
        let (a, out) = makeArbiter([zh])
        a.receive(.init(slot: 0, text: "直接放行", confidence: 0.5, range: range(0, 1), segments: []))
        checkEqual(out().count, 1, "單語言直通")
    }

    // 8. 草稿顯示規則：文字系統對不上就不顯示。
    do {
        let (a, _) = makeArbiter([en, zh])
        check(a.shouldShowDraft(from: 1, text: "Good morning everyone", confidence: -1) == false, "中文通道吐英文草稿 → 不顯示")
        check(a.shouldShowDraft(from: 0, text: "Good morning everyone", confidence: -1), "英文通道英文草稿 → 顯示")
        check(a.shouldShowDraft(from: 1, text: "早", confidence: -1), "太短不檢查文字系統 → 顯示")
    }
}

// ---- TaiwanWording：OpenCC 表 + 自訂規則 ----
do {
    checkEqual(TaiwanWording.apply("這個軟件的默認值在服務器上"), "這個軟體的預設值在伺服器上", "OpenCC 詞彙")
    checkEqual(TaiwanWording.apply("我的膝上型電腦和賬號"), "我的筆記型電腦和帳號", "extra 規則")
    checkEqual(TaiwanWording.apply("臺灣的平臺"), "台灣的平台", "臺→台")
    checkEqual(TaiwanWording.apply("視頻會議"), "視訊會議", "長詞優先（視頻會議→視訊會議，不是 影片會議）")
    let rules = TaiwanWording.parseRules("馬克=Mark\n  渠道 = 管道 \n壞行\n=空")
    checkEqual(rules.count, 2, "parseRules 只收合法行")
    checkEqual(TaiwanWording.apply("馬克用渠道", custom: rules), "Mark用管道", "自訂規則優先於內建")
    checkEqual(TaiwanWording.apply("Hello world"), "Hello world", "英文不動")
    var d = AppSettingsData()
    d.vocabulary = " OpenAI \nCodex\n\nOpenAI\nCathay"
    checkEqual(d.vocabularyTerms, ["OpenAI", "Codex", "Cathay"], "詞彙表去空白去重")
}

// ---- SessionRecorder：兩路 inject 一秒，應寫出約一秒的 .m4a ----
do {
    let hub = AudioHub()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-test-\(UUID().uuidString).m4a")
    let rec = SessionRecorder(url: url)
    var started = false
    do { try rec.start(hub: hub, kinds: [.system, .microphone]); started = true }
    catch { check(false, "recorder start: \(error.localizedDescription)") }
    if started {
        let tone = (0..<1_600).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.5 }
        for _ in 0..<10 {
            hub.inject(.system, tone)
            hub.inject(.microphone, [Float](repeating: 0, count: 1_600))
            Thread.sleep(forTimeInterval: 0.1)
        }
        let done = DispatchSemaphore(value: 0)
        var seconds = 0.0
        Task { seconds = (await rec.stop()).seconds; done.signal() }
        done.wait()
        check(seconds >= 0.9 && seconds <= 1.6, "錄音長度約一秒（\(seconds)）")
        if let f = try? AVAudioFile(forReading: url) {
            check(f.length >= 14_000, "m4a 可讀且長度合理（\(f.length) frames）")
            checkEqual(Int(f.fileFormat.sampleRate), 16_000, "m4a 取樣率")
            // 讀回來應該有聲音（系統那一路是 440 Hz 正弦波）
            if let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
               (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] {
                var peak: Float = 0
                vDSP_maxmgv(ch, 1, &peak, vDSP_Length(buf.frameLength))
                check(peak > 0.3, "錄音內容不是靜音（peak \(peak)）")
            } else {
                check(false, "m4a 讀回失敗")
            }
        } else {
            check(false, "m4a 無法開啟")
        }
        try? FileManager.default.removeItem(at: url)
    }
}

// ---- HistoryStore：背景載入不能復活刪除的紀錄或蓋掉剛存的內容 ----
MainActor.assumeIsolated {
    func record(_ text: String, at seconds: Double) -> SessionRecord {
        let date = Date(timeIntervalSince1970: seconds)
        return SessionRecord(id: UUID(), startedAt: date, endedAt: date.addingTimeInterval(60),
                             source: .system, target: zh,
                             panes: [.init(language: en, target: zh,
                                           lines: [.init(id: 0, time: date, original: text,
                                                         translated: nil, source: .system)])])
    }
    func pump(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(done(), "history async work completed")
    }
    let deleted = record("delete me", at: 100)
    let original = record("old text", at: 200)
    let unchanged = record("keep me", at: 300)
    let snapshot = [deleted, original, unchanged]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    release.signal()
    let store = HistoryStore(directory: dir, readRecords: { _ in
        started.signal()
        release.wait()
        return snapshot
    })
    check(started.wait(timeout: .now() + 5) == .success, "history initial read started")
    pump { store.sessions.count == 3 }

    let loading = store.load()
    check(started.wait(timeout: .now() + 5) == .success, "history reload snapshot in flight")
    var updated = original
    updated.panes[0].lines[0].original = "updated text"
    let fresh = record("new session", at: 400)
    store.save(updated)
    store.save(fresh)
    store.delete(deleted)
    release.signal()
    var completed = false
    Task { @MainActor in await loading.value; completed = true }
    pump { completed }
    checkEqual(store.sessions.map(\.id), [fresh.id, unchanged.id, updated.id],
               "history sorted; deleted snapshot stays deleted and new record survives")
    checkEqual(store.sessions.last?.preview, "updated text", "history update wins over stale disk snapshot")

    // 用真正的 JSON 讀取器驗證儲存與載入，而非只有測試用的背景快照。
    let reloaded = HistoryStore(directory: dir)
    let diskLoad = reloaded.load()
    completed = false
    Task { @MainActor in await diskLoad.value; completed = true }
    pump { completed }
    checkEqual(reloaded.sessions.map(\.id), [fresh.id, updated.id], "history JSON round trip")
    checkEqual(reloaded.sessions.last?.preview, "updated text", "history updated text persisted")
}

// ---- Timeline：5 分鐘一格 ----
do {
    let cal = Calendar.current
    let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 14, minute: 3, second: 20))!
    checkEqual(Timeline.bucket(base), Timeline.bucket(base.addingTimeInterval(90)), "14:03 與 14:04 同一格")
    check(Timeline.bucket(base) != Timeline.bucket(base.addingTimeInterval(120)), "14:03 與 14:05 不同格")
    checkEqual(Timeline.label(base), "14:00", "格線標籤是該格起始時間")
    checkEqual(Timeline.label(base.addingTimeInterval(120)), "14:05", "下一格 14:05")
}

// ---- L10n：四種介面語言都要有字串，缺的會退回英文 ----
do {
    checkEqual(L10n.incompleteKeys(), [], "每個 key 都有四種語言")
    let saved = L10n.language
    defer { L10n.language = saved }
    L10n.language = .ja
    checkEqual(tr("start"), "開始", "ja start")
    checkEqual(tr("history"), "履歴", "ja history")
    checkEqual(trf("history.lines", 3), "3 文", "ja format")
    L10n.language = .ko
    checkEqual(tr("start"), "시작", "ko start")
    checkEqual(trf("pane.add.max", 4), "최대 4개 패널", "ko format")
    checkEqual(tr("no.such.key"), "no.such.key", "未知 key 回傳 key")
    L10n.language = .en
    checkEqual(tr("start"), "Start", "en start")
    checkEqual(UILanguage.ja.localeIdentifier, "ja_JP", "ja locale")
    checkEqual(UILanguage.ko.localeIdentifier, "ko_KR", "ko locale")
}

// MARK: - Dedup（混合模式跨來源去重）
do {
    check(Dedup.isDuplicate("Hello, world! How are you today?", "hello world how are you today"), "大小寫標點不同 → 同一句")
    check(Dedup.isDuplicate("We need to finalize the contract with Cathay by Friday.",
                            "We need to finalise the contract with Cathay by Friday"), "一字之差 → 同一句")
    check(Dedup.isDuplicate("今天的會議先討論合約內容，然後再看時程。", "今天的會議先討論合約內容然後再看時程"), "中文標點差異 → 同一句")
    check(Dedup.isDuplicate("Let's start with the agenda.", "Let's start with the agenda. Then we go through the numbers."),
          "一條長一條短、短的整段包含在長的裡 → 同一句")
    check(Dedup.isDuplicate("OK", "OK, let's go through the numbers for next quarter.") == false, "短句包含不算（避免誤殺）")
    check(Dedup.isDuplicate("The budget was approved yesterday.", "The meeting is scheduled for Monday.") == false, "不同句")
    check(Dedup.isDuplicate("", "anything") == false, "空字串不算")
    checkEqual(Dedup.similarity(Dedup.normalize("abcd"), Dedup.normalize("abcd")), 1.0, "完全相同相似度 1")
    check(Dedup.similarity(Dedup.normalize("abcdefghij"), Dedup.normalize("abcdefghix")) >= 0.9, "差一字 ≥ 0.9")
}

print(failures == 0 ? "✓ \(total) checks passed" : "✗ \(failures)/\(total) checks failed")
exit(failures == 0 ? 0 : 1)
