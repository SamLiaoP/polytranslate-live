import CoreMedia
import Foundation

/// 多語言並行辨識 + 仲裁。
///
/// 每個擷取來源（系統聲音、麥克風）各開「語言數」條辨識通道，全部聽同一份音訊。
/// 每句定稿時，比較各語言通道對同一段音訊的信心值，只放行最高的那一條，其餘丟掉。
/// 做法參考 audicap 的實測經驗：
///   · 不能用固定時間窗配對，各語言的斷句邊界差很多，要用音訊時間範圍是否重疊來分組。
///   · 分離度通常很大（英語音訊：en 0.87 / zh 0.58），所以上一句的語言只給很小的加分，
///     才不會壓住真正的語言切換。
///   · 文字系統對不上（中文通道吐出假名、日文通道吐出全漢字長句）要扣分。
@MainActor
final class RecognitionEngine {
    struct LaneKey: Hashable {
        let capture: CaptureKind
        let slot: Int
    }

    /// slot = 語言在 languages 陣列中的索引。
    var onFinal: ((_ slot: Int, _ capture: CaptureKind, _ text: String) -> Void)?
    /// 空字串代表清掉該來源在該欄的草稿。
    var onDraft: ((_ slot: Int, _ capture: CaptureKind, _ text: String) -> Void)?
    var onStatus: ((_ slot: Int, _ text: String) -> Void)?
    var onError: ((_ text: String) -> Void)?

    private(set) var isRunning = false
    private var channels: [LaneKey: SpeechChannel] = [:]
    private var subscriptions: [UUID] = []
    private var arbiters: [CaptureKind: Arbiter] = [:]
    private var languages: [Language] = []

    func start(languages: [Language], captures: [CaptureKind], hub: AudioHub,
               tuning: @escaping () -> ArbiterTuning = { .standard }) async throws {
        guard !isRunning else { return }
        self.languages = languages
        var started: [LaneKey: SpeechChannel] = [:]
        var failures: [String] = []

        for capture in captures {
            let arbiter = Arbiter(languages: languages, tuning: tuning)
            arbiter.onEmit = { [weak self] slot, text in
                guard let self else { return }
                onFinal?(slot, capture, text)
                for other in languages.indices where other != slot {
                    onDraft?(other, capture, "")
                }
            }
            arbiters[capture] = arbiter

            for (slot, lang) in languages.enumerated() {
                let key = LaneKey(capture: capture, slot: slot)
                let ch = SpeechChannel(locale: Locale(identifier: lang.speechLocale))
                ch.onEvent = { [weak self] event in
                    Task { @MainActor in self?.handle(event, key: key) }
                }
                do {
                    try await ch.start()
                    started[key] = ch
                    dlog("lane ready: \(capture.rawValue)/\(lang.speechLocale)")
                } catch {
                    failures.append("\(lang.name)：\(error.localizedDescription)")
                    dlog("lane failed: \(capture.rawValue)/\(lang.speechLocale): \(error.localizedDescription)")
                }
            }
        }

        guard !started.isEmpty else {
            arbiters.removeAll()
            throw EngineError.noLane(failures.joined(separator: "\n"))
        }
        if !failures.isEmpty {
            onError?(failures.joined(separator: "\n"))
        }
        channels = started
        for (key, ch) in started {
            subscriptions.append(hub.subscribe(key.capture) { samples in ch.append(samples) })
        }
        isRunning = true
        for slot in languages.indices { onStatus?(slot, tr("status.listening")) }
    }

    func stop(hub: AudioHub) async {
        guard isRunning else { return }
        for id in subscriptions { hub.unsubscribe(id) }
        subscriptions.removeAll()
        for arbiter in arbiters.values { arbiter.cancelAll() }
        arbiters.removeAll()
        for ch in channels.values { await ch.stop() }
        channels.removeAll()
        isRunning = false
    }

    private func handle(_ event: SpeechEvent, key: LaneKey) {
        guard isRunning, let arbiter = arbiters[key.capture] else { return }
        switch event {
        case .status(let s):
            onStatus?(key.slot, s)
        case .error(let e):
            onError?("\(languages[key.slot].name)（\(key.capture.label)）：\(e)")
        case .result(let r):
            if r.isFinal {
                arbiter.receive(Arbiter.Candidate(slot: key.slot, text: r.text, confidence: r.confidence,
                                                  range: r.range, segments: r.segments))
            } else {
                let trimmed = ScriptDetector.trimLeadingMismatch(r.text, languages[key.slot])
                let show = !trimmed.isEmpty && arbiter.shouldShowDraft(from: key.slot, text: trimmed, confidence: r.confidence)
                dlog("draft \(languages[key.slot].speechLocale) show=\(show): \(trimmed.suffix(40))")
                onDraft?(key.slot, key.capture, show ? trimmed : "")
            }
        }
    }

    enum EngineError: LocalizedError {
        case noLane(String)
        var errorDescription: String? {
            switch self {
            case .noLane(let detail): return trf("err.noLane", detail)
            }
        }
    }
}

/// 單一來源的仲裁器：同一段音訊，哪個語言的定稿信心值高就放行哪個。
@MainActor
final class Arbiter {
    struct Candidate {
        var slot: Int
        var text: String
        var confidence: Double   // < 0 = 沒有信心值
        var range: CMTimeRange
        var segments: [SpeechSegment]
    }

    private final class Group {
        var range: CMTimeRange
        var candidates: [Candidate]
        var task: Task<Void, Never>?
        init(_ c: Candidate) { range = c.range; candidates = [c] }
    }

    var onEmit: ((_ slot: Int, _ text: String) -> Void)?

    private let languages: [Language]
    /// 每次用到時讀最新設定，所以在設定裡調整會立即生效。
    private let tuning: () -> ArbiterTuning
    private var groups: [Group] = []
    private var emitted: [CMTimeRange] = []
    private var preferred: Int?
    private var preferredAt = Date.distantPast

    // 固定參數（來自 audicap 的實測）；可調的門檻在 ArbiterTuning。
    private let waitSec = 1.0            // 等其他語言補齊的時間
    private let lowConfWaitSec = 3.5     // 最佳候選也沒把握時多等（各語言定稿時間差可到 4 秒）
    private let lowConfLine = 0.80
    private let biasHoldSec = 12.0       // 停頓太久就不再偏向
    private let scriptMismatchPenalty = 0.25
    private let scriptCheckMinChars = 4
    private let loneShortSec = 2.5

    init(languages: [Language], tuning: @escaping () -> ArbiterTuning = { .standard }) {
        self.languages = languages
        self.tuning = tuning
    }

    /// 草稿要不要顯示：
    ///   · 文字系統跟這一路的語言對不上（中文通道吐出一串拉丁字母）→ 不顯示。
    ///   · 目前偏好的語言：信心值別太低就顯示。
    ///   · 非偏好語言：要有相當把握才顯示，避免英文講到一半右欄冒出中文通道的亂碼。
    ///   · 還沒有偏好：中等把握就顯示。
    func shouldShowDraft(from slot: Int, text: String, confidence: Double) -> Bool {
        // 實測：草稿（volatile）沒有信心值，只能靠文字系統擋掉最明顯的錯路
        // （中文通道聽英文會吐出一串拉丁字母，這種直接不顯示）。
        if text.count >= scriptCheckMinChars && !ScriptDetector.scriptMatches(text, languages[slot]) { return false }
        if confidence >= 0 {
            let holding = preferred != nil && Date().timeIntervalSince(preferredAt) < biasHoldSec
            if holding && preferred != slot { return confidence >= 0.60 }
            return confidence >= 0.30
        }
        return true
    }

    func receive(_ raw: Candidate) {
        var c = raw
        guard !c.text.isEmpty else { return }
        if c.confidence >= 0 && c.confidence < tuning().junkConfidence {
            dlog("arbiter drop junk \(languages[c.slot].speechLocale) conf=\(String(format: "%.2f", c.confidence)): \(c.text.prefix(40))")
            return
        }
        if languages.count == 1 { emit(c); return }

        // 這段音訊裡已經放行過別人的部分要剪掉：各語言的斷句邊界不同，
        // 中文通道常把前一句英文和這句中文合成一個長定稿，只留沒被放行過的那幾段。
        if !c.segments.isEmpty {
            var kept = c.segments.filter { coveredFraction($0.range) < 0.35 }
            for seg in c.segments where coveredFraction(seg.range) >= 0.35 {
                dlog("arbiter   cut covered \(String(format: "%.1f–%.1f", seg.range.start.seconds, seg.range.end.seconds)): \(seg.text.prefix(30))")
            }
            // 頭尾殘留的、文字系統跟這一路語言對不上的碎片（例如中文通道前面黏著的「and.」）也剪掉。
            while let f = kept.first, !ScriptDetector.segmentFits(f.text, languages[c.slot]) || !hasLetters(f.text) {
                dlog("arbiter   cut head: \(f.text.prefix(30))")
                kept.removeFirst()
            }
            while let l = kept.last, !ScriptDetector.segmentFits(l.text, languages[c.slot]) || !hasLetters(l.text) {
                dlog("arbiter   cut tail: \(l.text.prefix(30))")
                kept.removeLast()
            }
            if kept.count < c.segments.count {
                let text = kept.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, kept.contains(where: { $0.text.unicodeScalars.contains { CharacterSet.letters.contains($0) } }) else {
                    dlog("arbiter drop covered \(languages[c.slot].speechLocale): \(c.text.prefix(40))")
                    return
                }
                let confs = kept.map(\.confidence).filter { $0 >= 0 }
                c.text = text
                c.range = kept.dropFirst().reduce(kept[0].range) { CMTimeRangeGetUnion($0, otherRange: $1.range) }
                c.confidence = confs.isEmpty ? -1 : confs.reduce(0, +) / Double(confs.count)
                c.segments = kept
                dlog("arbiter trimmed \(languages[c.slot].speechLocale) → \(text.prefix(40))")
            }
        } else if coveredFraction(c.range) > 0.5 {
            dlog("arbiter drop covered \(languages[c.slot].speechLocale): \(c.text.prefix(40))")
            return
        }
        dlog("arbiter cand \(languages[c.slot].speechLocale) conf=\(String(format: "%.2f", c.confidence)) \(String(format: "%.1f–%.1f", c.range.start.seconds, c.range.end.seconds)): \(c.text.prefix(40))")

        if let g = groups.first(where: { intersects($0.range, c.range) }) {
            g.candidates.append(c)
            g.range = CMTimeRangeGetUnion(g.range, otherRange: c.range)
            if Set(g.candidates.map(\.slot)).count >= languages.count { decide(g) }
            return
        }

        // 直通：目前語言、信心值很高，不等別人。
        if let p = preferred, c.slot == p, c.confidence >= tuning().fastPassConfidence,
           Date().timeIntervalSince(preferredAt) < biasHoldSec {
            emit(c)
            return
        }

        let g = Group(c)
        groups.append(g)
        let wait = (c.confidence >= 0 && c.confidence < lowConfLine) ? lowConfWaitSec : waitSec
        g.task = Task { [weak self, weak g] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let g else { return }
            decide(g)
        }
    }

    func cancelAll() {
        for g in groups { g.task?.cancel() }
        groups.removeAll()
    }

    private func decide(_ g: Group) {
        g.task?.cancel()
        groups.removeAll { $0 === g }
        guard let best = g.candidates.max(by: { score($0) < score($1) }) else { return }
        // 只有一個候選、信心值低、又很短：多半是別的語言的碎片被誤收（例如中文通道聽日文吐出「註話」）。
        // 放行會把這段音訊標成「已處理」，害正確語言晚到的定稿被剪掉，所以直接丟。
        // 實測：正確語言的定稿信心值最低看過 0.65；錯誤語言的垃圾在 0.18–0.55 之間。門檻可在設定調整。
        let t = tuning()
        if g.candidates.count == 1, best.confidence >= 0, best.confidence < t.loneStrictBelow {
            let mismatch = best.text.count >= scriptCheckMinChars && !ScriptDetector.scriptMatches(best.text, languages[best.slot])
            if best.confidence < t.loneDropBelow || mismatch || best.range.duration.seconds < loneShortSec {
                dlog("arbiter drop lone-low \(languages[best.slot].speechLocale) conf=\(String(format: "%.2f", best.confidence)) mismatch=\(mismatch): \(best.text.prefix(40))")
                return
            }
        }
        if g.candidates.count > 1 {
            let desc = g.candidates.map { "\(languages[$0.slot].name)=\(String(format: "%.2f", $0.confidence))" }.joined(separator: " ")
            dlog("arbiter: \(desc) → \(languages[best.slot].name)")
        }
        emit(best)
    }

    private func score(_ c: Candidate) -> Double {
        let conf = c.confidence < 0 ? 0.5 : c.confidence
        let mismatch = c.text.count >= scriptCheckMinChars && !ScriptDetector.scriptMatches(c.text, languages[c.slot])
        if mismatch { return conf - scriptMismatchPenalty }
        let biased = preferred == c.slot && Date().timeIntervalSince(preferredAt) < biasHoldSec
        return conf + (biased ? tuning().preferredBonus : 0)
    }

    private func emit(_ c: Candidate) {
        emitted.append(c.range)
        if emitted.count > 60 { emitted.removeFirst(emitted.count - 60) }
        preferred = c.slot
        preferredAt = Date()
        onEmit?(c.slot, c.text)
    }

    private func intersects(_ a: CMTimeRange, _ b: CMTimeRange) -> Bool {
        let i = CMTimeRangeGetIntersection(a, otherRange: b)
        return CMTIME_IS_VALID(i.duration) && i.duration.seconds > 0.2
    }

    private func hasLetters(_ t: String) -> Bool {
        t.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    /// 這段時間範圍有多少比例已經被放行過的結果蓋住（0–1）。
    private func coveredFraction(_ r: CMTimeRange) -> Double {
        guard r.duration.seconds > 0 else { return 0 }
        var covered = 0.0
        for e in emitted {
            let i = CMTimeRangeGetIntersection(r, otherRange: e)
            if CMTIME_IS_VALID(i.duration) { covered += i.duration.seconds }
        }
        return min(1, covered / r.duration.seconds)
    }
}
