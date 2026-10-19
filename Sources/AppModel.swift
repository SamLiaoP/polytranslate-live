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
    /// 等使用者確認要不要刪的紀錄（刪除無法復原，所以要問一下）。
    @Published var sessionPendingDelete: SessionRecord?

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
        let list = LanguageCatalog.all.filter { supportedSpeechLocales.contains($0.speechBCP47) }
        // 比對方式萬一跟系統格式對不上，寧可全列也不要給一個空選單。
        return list.isEmpty ? LanguageCatalog.all : list
    }

    func setTarget(_ id: String) {
        guard !isRunning else { return }
        settings.data.targetLanguage = id
        let t = target
        for p in panes { p.target = t; p.clearError() }
    }

    /// 這個語言是不是已經有別的欄在聽（選單裡要反灰）。
    func isLanguageUsed(_ id: String, except pane: PaneEngine? = nil) -> Bool {
        panes.contains { $0 !== pane && $0.language.id == id }
    }

    func setPaneLanguage(_ pane: PaneEngine, _ id: String) {
        guard !isRunning, let i = panes.firstIndex(where: { $0 === pane }) else { return }
        guard !isLanguageUsed(id, except: pane) else { return }
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
        engine.onLanesExhausted = { [weak self] in
            dlog("all lanes dead; stopping session")
            Task { await self?.stop() }
        }
    }

    private func loadSpeechLocales() async {
        if #available(macOS 26.0, *) {
            let locales = await SpeechTranscriber.supportedLocales
            supportedSpeechLocales = Set(locales.map { $0.identifier(.bcp47) })
            dlog("speech locales: \(supportedSpeechLocales.sorted().joined(separator: " "))")
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
        // 先不清上一輪的字幕：權限被拒或引擎起不來的話，使用者不該平白失去畫面上的內容。
        for pane in panes { pane.sessionStarted() }

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
            let settings = self.settings
            try await engine.start(languages: languages, captures: captures, hub: hub,
                                   tuning: { settings.data.arbiter })
        } catch {
            dlog("engine start failed: \(error.localizedDescription)")
            globalError = error.localizedDescription
            testFeedTask?.cancel()
            await hub.stopAll()
            for pane in panes { pane.sessionStopped() }
            return
        }
        for pane in panes { pane.clear() }
        startedAt = Date()
        isRunning = true
    }

    func stop() async {
        // 還在啟動中（例如正在下載模型）就先等它起來，不然 start 會在我們背後把來源又打開。
        var waited = 0
        while isStarting && waited < 600 {   // 最多 30 秒
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        guard isRunning else { return }
        testFeedTask?.cancel()
        await engine.stop(hub: hub)      // 這裡會把最後一句定稿送進各欄
        await hub.stopAll()
        for pane in panes { pane.sessionStopped() }
        isRunning = false
        // 最後幾句的翻譯可能還在跑，等一下再存，不然歷史紀錄裡最後一句沒有譯文。
        let panes = self.panes
        await withTaskGroup(of: Void.self) { group in
            for p in panes { group.addTask { @MainActor in await p.waitForTranslations(seconds: 3) } }
        }
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
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"   // 到秒，同一分鐘停兩次不會互相覆蓋
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(tr("transcript.folder"), isDirectory: true)
        let url = dir.appendingPathComponent("\(f.string(from: record.startedAt)).md")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try HistoryStore.markdown(record).write(to: url, atomically: true, encoding: .utf8)
            dlog("transcript saved: \(url.lastPathComponent)")
        } catch {
            dlog("transcript save failed: \(error.localizedDescription)")
            globalError = trf("err.transcriptSave", error.localizedDescription)
        }
    }
}
