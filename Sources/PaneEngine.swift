import Foundation

/// 一個字幕欄：接收某一種語言的定稿與草稿，翻成另一種語言。
/// 辨識不在這裡做（見 RecognitionEngine），這裡只負責顯示資料與翻譯佇列。
@MainActor
final class PaneEngine: ObservableObject, Identifiable {
    let id: String
    @Published var language: Language        // 聽的語言
    @Published var target: Language          // 翻成的語言
    @Published private(set) var lines: [SubtitleLine] = []
    @Published private(set) var drafts: [CaptureKind: String] = [:]
    @Published private(set) var draftTranslations: [CaptureKind: String] = [:]
    @Published private(set) var status = ""
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var translationHint: String?

    private var nextLineID = 0
    private var draftTasks: [CaptureKind: Task<Void, Never>] = [:]
    private var lastDraftSent: [CaptureKind: String] = [:]
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

    func setStatus(_ s: String) { status = s }
    func setError(_ e: String) { lastError = e }

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
        dlog("[\(id)] final(\(source.rawValue)): \(text)")
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

    /// 開始時先確認語言包有沒有裝，沒有就提早告訴使用者。
    private func checkTranslationReadiness() {
        guard settings.data.backend == .apple, !sameLanguage else { return }
        let lang = language, tgt = target
        Task { [weak self] in
            guard let self else { return }
            if let st = await translator.appleStatus(from: lang.speechLocale, to: tgt.translation) {
                switch st {
                case .unsupported where lang.translation != tgt.translation:
                    lastError = TranslatorError.unsupportedPair(source: lang.translation, target: tgt.translation).localizedDescription
                default:
                    break
                }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let t = try await translator.translate(line.original, fromSpeechLocale: lang.speechLocale,
                                                       to: tgt.translation, recentContext: Array(context))
                if let i = lines.firstIndex(where: { $0.id == line.id }) {
                    lines[i].translated = t
                    lastError = nil
                }
                dlog("[\(id)] translated: \(t)")
                if settings.data.backend == .apple, translationHint == nil,
                   await translator.appleUsingFallback(from: lang.speechLocale, to: tgt.translation) {
                    translationHint = tr("hint.online")
                }
            } catch {
                dlog("[\(id)] translate error: \(error.localizedDescription)")
                if let i = lines.firstIndex(where: { $0.id == line.id }) {
                    lines[i].translationFailed = true
                }
                lastError = error.localizedDescription
            }
        }
    }

    /// 草稿翻譯：等 350 ms 沒有新字再送，避免每個音節都翻一次。
    private func scheduleDraftTranslation(_ source: CaptureKind) {
        guard settings.data.translateDrafts, settings.data.backend == .apple, !sameLanguage else { return }
        draftTasks[source]?.cancel()
        guard let text = drafts[source], text.count >= 2, text != lastDraftSent[source] else { return }
        let lang = language, tgt = target
        draftTasks[source] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            lastDraftSent[source] = text
            guard let t = try? await translator.translate(text, fromSpeechLocale: lang.speechLocale, to: tgt.translation) else { return }
            if !Task.isCancelled, let current = drafts[source], current.hasPrefix(text) || current == text {
                draftTranslations[source] = t
            }
        }
    }

    func transcriptText(showSource: Bool) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return lines.map { line in
            var s = "[\(f.string(from: line.timestamp))]"
            if showSource { s += "（\(line.source.label)）" }
            s += " \(line.original)"
            if let t = line.translated { s += "\n    → \(t)" }
            return s
        }.joined(separator: "\n")
    }
}
