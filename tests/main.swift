// 純邏輯的單元測試：ScriptDetector、Arbiter、LanguageMap。
// 不用 XCTest（Command Line Tools 不一定有），一個小的斷言框架就夠。
//   ./build.sh test
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

print(failures == 0 ? "✓ \(total) checks passed" : "✗ \(failures)/\(total) checks failed")
exit(failures == 0 ? 0 : 1)
