import AppKit
import AVFoundation
import Foundation
import Speech

/// 整個 App 的狀態：設定、音訊來源、辨識引擎、N 個字幕欄。
/// 所有字幕欄共用一個目標語言；每欄聽一種語言。
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let translator: TranslatorHub
    let hub = AudioHub()
    let engine = RecognitionEngine()
    let history = HistoryStore()

    @Published private(set) var panes: [PaneEngine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var startedAt: Date?
    @Published var globalError: String?
    @Published private(set) var supportedSpeechLocales: Set<String> = []
    @Published var showSettings = false
    /// 正在回看的歷史紀錄；nil = 顯示即時字幕。
    @Published var selectedSession: SessionRecord?

    static let maxPanes = 4

    /// `PolyTranslateLive --test-wav 檔案.wav`：不開麥克風與系統聲音，改把 wav 以真實時間速度灌進「系統聲音」通道，
    /// 並自動開始。用來在沒有權限、沒有人講話的情況下驗證整條管線。
    private let testWAV: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--test-wav"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }()
    private var testFeedTask: Task<Void, Never>?
    /// 引擎 slot → 字幕欄。沒有對應的 slot 是「吸收用」的目標語言通道，結果丟掉。
    private var slotToPane: [Int: PaneEngine] = [:]
    private var paneSeq = 0

    init() {
        let settings = AppSettings()
        self.settings = settings
        settings.data.backend = .apple
        let translator = TranslatorHub(settings: settings)
        self.translator = translator

        hub.onSystemAudioError = { [weak self] error in
            Task { @MainActor in
                self?.globalError = trf("err.systemAudioInterrupted", error.localizedDescription)
            }
        }
        rebuildPanes()
        wireEngine()
        dlog("---- launch; log at \(DebugLog.shared.url.path)")
        Task { await loadSpeechLocales() }
        if testWAV != nil {
            Task {
                try? await Task.sleep(for: .seconds(1))
                await start()
            }
        }
    }

    // MARK: 語言

    var target: Language { LanguageCatalog.language(settings.data.targetLanguage) }

    /// 可選的語言清單（排除這台機器語音辨識不支援的）。
    var availableLanguages: [Language] {
        guard !supportedSpeechLocales.isEmpty else { return LanguageCatalog.all }
        return LanguageCatalog.all.filter { supportedSpeechLocales.contains($0.speechLocale) }
    }

    func setTarget(_ id: String) {
        guard !isRunning else { return }
        settings.data.targetLanguage = id
        let t = target
        for p in panes { p.target = t; p.clearError() }
    }

    func setPaneLanguage(_ pane: PaneEngine, _ id: String) {
        guard !isRunning, let i = panes.firstIndex(where: { $0 === pane }) else { return }
        settings.data.paneLanguages[i] = id
        pane.language = LanguageCatalog.language(id)
        pane.clearError()
    }

    var canAddPane: Bool { panes.count < Self.maxPanes && !isRunning }

    /// 新增一欄：挑一個還沒有欄位在聽的語言。
    func addPane() {
        guard canAddPane else { return }
        let used = Set(settings.data.paneLanguages)
        let candidate = availableLanguages.first { !used.contains($0.id) && $0.id != settings.data.targetLanguage }
            ?? availableLanguages.first { !used.contains($0.id) }
            ?? LanguageCatalog.all[0]
        settings.data.paneLanguages.append(candidate.id)
        panes.append(makePane(language: candidate))
    }

    func removePane(_ pane: PaneEngine) {
        guard !isRunning, panes.count > 1, let i = panes.firstIndex(where: { $0 === pane }) else { return }
        panes.remove(at: i)
        settings.data.paneLanguages.remove(at: i)
    }

    private func makePane(language: Language) -> PaneEngine {
        paneSeq += 1
        return PaneEngine(id: "P\(paneSeq)", language: language, target: target, translator: translator, settings: settings)
    }

    private func rebuildPanes() {
        if settings.data.paneLanguages.isEmpty { settings.data.paneLanguages = ["en"] }
        panes = settings.data.paneLanguages.map { makePane(language: LanguageCatalog.language($0)) }
    }

    // MARK: 引擎

    private func wireEngine() {
        engine.onFinal = { [weak self] slot, capture, text in
            guard let self else { return }
            if let p = slotToPane[slot] { p.receiveFinal(text, from: capture) }
            else { dlog("absorbed (\(capture.rawValue)): \(text)") }
        }
        engine.onDraft = { [weak self] slot, capture, text in
            self?.slotToPane[slot]?.receiveDraft(text, from: capture)
        }
        engine.onStatus = { [weak self] slot, text in
            self?.slotToPane[slot]?.setStatus(text)
        }
        engine.onError = { [weak self] text in
            self?.globalError = text
        }
    }

    private func loadSpeechLocales() async {
        if #available(macOS 26.0, *) {
            let locales = await SpeechTranscriber.supportedLocales
            supportedSpeechLocales = Set(locales.map(\.identifier))
        }
    }

    func toggle() {
        Task { isRunning ? await stop() : await start() }
    }

    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        globalError = nil
        selectedSession = nil
        for pane in panes { pane.clear(); pane.sessionStarted() }

        // 辨識語言 = 各欄的語言，再加上目標語言當「吸收通道」：
        // 有人說目標語言時，由它贏得仲裁並被丟掉，不會變成別欄的亂碼。
        var languages: [Language] = []
        slotToPane.removeAll()
        for pane in panes {
            if let existing = languages.firstIndex(where: { $0.speechLocale == pane.language.speechLocale }) {
                slotToPane[existing] = pane   // 兩欄同語言：後者接管（實務上不會這樣設）
            } else {
                slotToPane[languages.count] = pane
                languages.append(pane.language)
            }
        }
        if !languages.contains(where: { $0.speechLocale == target.speechLocale }) {
            languages.append(target)
        }

        let captures = settings.data.source.captures
        if let testWAV {
            dlog("TEST MODE: feeding \(testWAV.path) into system-audio channel")
            startTestFeed(testWAV)
        } else {
            do {
                try await hub.start(kinds: Set(captures))
            } catch {
                dlog("audio start failed: \(error.localizedDescription)")
                globalError = error.localizedDescription
                await hub.stopAll()
                for pane in panes { pane.sessionStopped() }
                return
            }
        }
        dlog("audio sources started: \(captures.map(\.rawValue)), languages: \(languages.map(\.speechLocale)), target: \(target.speechLocale)")

        do {
            try await engine.start(languages: languages, captures: captures, hub: hub)
        } catch {
            dlog("engine start failed: \(error.localizedDescription)")
            globalError = error.localizedDescription
            testFeedTask?.cancel()
            await hub.stopAll()
            for pane in panes { pane.sessionStopped() }
            return
        }
        startedAt = Date()
        isRunning = true
    }

    func stop() async {
        guard isRunning else { return }
        testFeedTask?.cancel()
        await engine.stop(hub: hub)
        await hub.stopAll()
        for pane in panes { pane.sessionStopped() }
        isRunning = false
        let started = startedAt ?? Date()
        startedAt = nil
        let record = SessionRecord(
            id: UUID(), startedAt: started, endedAt: Date(), source: settings.data.source, target: target,
            panes: panes.map { p in
                SessionRecord.Pane(language: p.language, target: p.target,
                                   lines: p.lines.map { SessionRecord.Line(id: $0.id, time: $0.timestamp, original: $0.original,
                                                                            translated: $0.translated, source: $0.source) })
            })
        history.save(record)
        if settings.data.saveTranscript, record.lineCount > 0 { saveTranscript(record) }
    }

    func copyToPasteboard(_ record: SessionRecord) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(HistoryStore.markdown(record), forType: .string)
    }

    func deleteSession(_ record: SessionRecord) {
        history.delete(record)
        if selectedSession?.id == record.id { selectedSession = nil }
    }

    private func startTestFeed(_ url: URL) {
        let hub = self.hub
        testFeedTask = Task.detached {
            guard let file = try? AVAudioFile(forReading: url) else { dlog("TEST MODE: cannot open wav"); return }
            let fmt = file.processingFormat
            let resampler = Resampler()
            let chunk = AVAudioFrameCount(fmt.sampleRate / 10)
            let start = Date()
            var fed = 0.0
            while !Task.isCancelled, file.framePosition < file.length,
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) {
                do { try file.read(into: buf) } catch { break }
                guard buf.frameLength > 0 else { break }
                if let s = resampler.process(buf) { hub.inject(.system, s) }
                fed += Double(buf.frameLength) / fmt.sampleRate
                let wait = start.addingTimeInterval(fed).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            for _ in 0..<30 where !Task.isCancelled {
                hub.inject(.system, [Float](repeating: 0, count: 1_600))
                try? await Task.sleep(for: .milliseconds(100))
            }
            dlog("TEST MODE: wav finished (\(String(format: "%.1f", fed))s); stopping")
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run { [weak self] in
                guard let self else { return }
                Task { await self.stop() }
            }
        }
    }

    private func saveTranscript(_ record: SessionRecord) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(tr("transcript.folder"), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(f.string(from: record.startedAt)).md")
        try? HistoryStore.markdown(record).write(to: url, atomically: true, encoding: .utf8)
    }
}
