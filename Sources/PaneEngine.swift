import Foundation

/// 一個字幕欄：接收某一種語言的定稿與草稿，翻成另一種語言。
/// 辨識不在這裡做（見 RecognitionEngine），這裡只負責顯示資料與翻譯佇列。
@MainActor
final class PaneEngine: ObservableObject, Identifiable {
    /// 欄位上方的錯誤訊息，以及它是不是「裝語言包就能解決」的那種（UI 據此決定要不要放下載按鈕）。
    struct PaneError: Equatable {
        var message: String
        var packMissing: Bool
    }

    let id: String
    @Published var language: Language        // 聽的語言
    @Published var target: Language          // 翻成的語言
    @Published private(set) var lines: [SubtitleLine] = []
    @Published private(set) var drafts: [CaptureKind: String] = [:]
    @Published private(set) var draftTranslations: [CaptureKind: String] = [:]
    @Published private(set) var status = ""
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: PaneError?
    @Published private(set) var translationHint: String?

    private var nextLineID = 0
    private var draftTasks: [CaptureKind: Task<Void, Never>] = [:]
    private var lastDraftSent: [CaptureKind: String] = [:]
    /// 還在跑的定稿翻譯；停止時等它們跑完，最後一句的譯文才會進歷史紀錄。
    private var translationTasks: [Int: Task<Void, Never>] = [:]
    private let translator: TranslatorHub
    private let settings: AppSettings
    private let maxLines = 400

    init(id: String, language: Language, target: Language, translator: TranslatorHub, settings: AppSettings) {
        self.id = id
        self.language = language
        self.target = target
        self.translator = translator
        self.settings = settings
    }

    var title: String { sameLanguage ? trf("pane.title.transcriptOnly", language.name) : "\(language.name) → \(target.name)" }

    /// 聽的語言就是目標語言：只顯示原文，不翻譯。
    var sameLanguage: Bool { language.translation == target.translation }

    /// 依時間排序的草稿（混合模式會有兩個來源）。
    var orderedDrafts: [(source: CaptureKind, text: String, translation: String)] {
        CaptureKind.allCases.compactMap { k in
            guard let t = drafts[k], !t.isEmpty else { return nil }
            return (k, t, draftTranslations[k] ?? "")
        }
    }

    func clearError() {
        lastError = nil
        translationHint = nil
    }

    func clear() {
        lines.removeAll()
        drafts.removeAll()
        draftTranslations.removeAll()
        lastError = nil
    }

    func sessionStarted() {
        isRunning = true
        lastError = nil
        status = tr("status.preparing")
        checkTranslationReadiness()
    }

    func sessionStopped() {
        isRunning = false
        for t in draftTasks.values { t.cancel() }
        draftTasks.removeAll()
        drafts.removeAll()
        draftTranslations.removeAll()
        status = tr("status.stopped")
    }

    /// 等還在跑的定稿翻譯結束（最多 `seconds` 秒）。停止時用，讓最後幾句的譯文進得了歷史紀錄。
    func waitForTranslations(seconds: Double) async {
        let tasks = Array(translationTasks.values)
        guard !tasks.isEmpty else { return }
        _ = await withTimeout(seconds) {
            for t in tasks { await t.value }
        }
    }

    /// 使用者剛下載完語言包：清掉提示、讓翻譯器丟掉退回線上的 session。
    func languagePackInstalled() {
        clearError()
        let lang = language, tgt = target
        Task { await translator.appleLanguagePackInstalled(from: lang.speechLocale, to: tgt.translation) }
    }

    func setStatus(_ s: String) { status = s }

    func receiveDraft(_ text: String, from source: CaptureKind) {
        if text.isEmpty {
            drafts[source] = nil
            draftTranslations[source] = nil
            draftTasks[source]?.cancel()
            return
        }
        drafts[source] = text
        scheduleDraftTranslation(source)
    }

    func receiveFinal(_ text: String, from source: CaptureKind) {
        dlogv("[\(id)] final(\(source.rawValue)): \(text)")
        draftTasks[source]?.cancel()
        drafts[source] = nil
        draftTranslations[source] = nil
        lastDraftSent[source] = nil
        guard Self.isMeaningful(text) else { return }
        let line = SubtitleLine(id: nextLineID, original: text, translated: nil, source: source, timestamp: Date())
        nextLineID += 1
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        translate(line: line)
    }

    /// 開始時先確認語言包狀態：不支援就提早報錯；支援但沒裝（會走線上）就先提示，不必等第一句翻完。
    private func checkTranslationReadiness() {
        guard settings.data.backend == .apple, !sameLanguage else { return }
        let lang = language, tgt = target
        Task { [weak self] in
            guard let self else { return }
            guard let st = await translator.appleStatus(from: lang.speechLocale, to: tgt.translation) else { return }
            switch st {
            case .unsupported:
                let msg = TranslatorError.unsupportedPair(source: lang.translation, target: tgt.translation).localizedDescription
                lastError = PaneError(message: msg, packMissing: false)
            case .supported:
                if translationHint == nil { translationHint = tr("hint.online") }
            default:
                break
            }
        }
    }

    private static func isMeaningful(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    private func translate(line: SubtitleLine) {
        guard !sameLanguage else { return }
        let lang = language, tgt = target
        let context = lines.suffix(4).dropLast().map(\.original)
        translationTasks[line.id] = Task { [weak self] in
            guard let self else { return }
            defer { translationTasks[line.id] = nil }
            do {
                let t = try await translator.translate(line.original, fromSpeechLocale: lang.speechLocale,
                                                       to: tgt.translation, recentContext: Array(context))
                if let i = lines.firstIndex(where: { $0.id == line.id }) {
                    lines[i].translated = t
                    lastError = nil
                }
                dlogv("[\(id)] translated: \(t)")
                if settings.data.backend == .apple, translationHint == nil,
                   await translator.appleUsingFallback(from: lang.speechLocale, to: tgt.translation) {
                    translationHint = tr("hint.online")
                }
            } catch {
                dlog("[\(id)] translate error: \(error.localizedDescription)")
                if let i = lines.firstIndex(where: { $0.id == line.id }) {
                    lines[i].translationFailed = true
                }
                var packMissing = false
                if case TranslatorError.languagePackMissing = error { packMissing = true }
                lastError = PaneError(message: error.localizedDescription, packMissing: packMissing)
            }
        }
    }

    /// 草稿翻譯：等 350 ms 沒有新字再送，避免每個音節都翻一次。
    /// 走線上備援（0.3–1 秒一筆）時不翻草稿，否則草稿會把定稿的翻譯擠在佇列後面。
    private func scheduleDraftTranslation(_ source: CaptureKind) {
        guard settings.data.translateDrafts, settings.data.backend == .apple, !sameLanguage else { return }
        draftTasks[source]?.cancel()
        guard let text = drafts[source], text.count >= 2, text != lastDraftSent[source] else { return }
        let lang = language, tgt = target
        draftTasks[source] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            if await translator.appleUsingFallback(from: lang.speechLocale, to: tgt.translation) { return }
            guard !Task.isCancelled else { return }
            lastDraftSent[source] = text
            guard let t = try? await translator.translate(text, fromSpeechLocale: lang.speechLocale, to: tgt.translation) else { return }
            if !Task.isCancelled, let current = drafts[source], current.hasPrefix(text) || current == text {
                draftTranslations[source] = t
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func transcriptText(showSource: Bool) -> String {
        let f = Self.timeFormatter
        return lines.map { line in
            var s = "[\(f.string(from: line.timestamp))]"
            if showSource { s += "（\(line.source.label)）" }
            s += " \(line.original)"
            if let t = line.translated { s += "\n    → \(t)" }
            return s
        }.joined(separator: "\n")
    }
}
