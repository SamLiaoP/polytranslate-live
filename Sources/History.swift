import Foundation

/// 一段錄音的歷史紀錄。每次按「停止」存一筆，一筆一個 JSON 檔。
struct SessionRecord: Identifiable, Codable, Equatable {
    struct Line: Codable, Equatable, Identifiable {
        var id: Int
        var time: Date
        var original: String
        var translated: String?
        var source: CaptureKind
    }
    struct Pane: Codable, Equatable {
        var language: Language
        var target: Language
        var lines: [Line]
    }

    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var source: AudioSourceKind
    var target: Language
    var panes: [Pane]
    /// 同資料夾裡的錄音檔名（.m4a）；沒開錄音或舊紀錄就是 nil。
    var recording: String? = nil

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var lineCount: Int { panes.reduce(0) { $0 + $1.lines.count } }
    /// DateFormatter 很貴，側欄每一列每次重繪都 new 一個會卡；每種介面語言各快取一個。
    private static let titleFormatters: [UILanguage: DateFormatter] = {
        var d: [UILanguage: DateFormatter] = [:]
        for ui in UILanguage.allCases {
            let f = DateFormatter()
            f.locale = Locale(identifier: ui.localeIdentifier)
            f.dateStyle = .medium
            f.timeStyle = .short
            d[ui] = f
        }
        return d
    }()
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 列表標題：日期 + 時間。
    var title: String {
        (Self.titleFormatters[L10n.language] ?? Self.titleFormatters[.en]!).string(from: startedAt)
    }
    var durationText: String {
        let s = Int(duration)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
    /// 第一句原文，當作預覽。
    var preview: String {
        panes.flatMap(\.lines).min(by: { $0.time < $1.time })?.original ?? ""
    }
}

/// 歷史紀錄存放在 ~/Library/Application Support/PolyTranslateLive/history/。
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []

    private let dir: URL
    private let readRecords: @Sendable (URL) -> [SessionRecord]
    private var loadGeneration = 0
    /// 載入期間有異動的 id；合併時以記憶體為準，包含已刪除的紀錄。
    private var changedDuringLoad: Set<UUID> = []
    private var isLoading = false
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    init(directory: URL? = nil,
         readRecords: @escaping @Sendable (URL) -> [SessionRecord] = { HistoryStore.readRecordsFromDisk($0) }) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.dir = directory ?? base.appendingPathComponent("PolyTranslateLive/history", isDirectory: true)
        self.readRecords = readRecords
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    nonisolated private static func readRecordsFromDisk(_ dir: URL) -> [SessionRecord] {
        // 每次載入各用一個 decoder，不在並行的背景工作之間共用。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
    }

    private func url(for id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    /// 這場 session 的錄音要寫到哪裡（和 JSON 同名不同副檔名）。
    func recordingURL(id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).m4a") }
    /// 有錄音檔才回傳；紀錄裡有檔名但檔案被手動刪掉也算沒有。
    func recordingURL(for record: SessionRecord) -> URL? {
        guard let name = record.recording else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 在背景讀檔，不卡啟動；幾百場會議的 JSON 在主執行緒同步讀會讓視窗晚出來。
    @discardableResult
    func load() -> Task<Void, Never> {
        loadGeneration += 1
        let generation = loadGeneration
        changedDuringLoad.removeAll()
        isLoading = true
        let dir = self.dir, readRecords = self.readRecords
        let reading = Task.detached(priority: .utility) { readRecords(dir) }
        return Task { [weak self] in
            let loaded = await reading.value
            guard let self, generation == loadGeneration else { return }
            // Set 查找避免舊版的雙層 contains（大量紀錄時為 O(n²)）。
            let changed = changedDuringLoad
            sessions = (sessions.filter { changed.contains($0.id) }
                        + loaded.filter { !changed.contains($0.id) })
                .sorted { $0.startedAt > $1.startedAt }
            changedDuringLoad.removeAll()
            isLoading = false
            dlog("history loaded: \(sessions.count) sessions")
        }
    }

    func save(_ record: SessionRecord) {
        guard record.lineCount > 0 || record.recording != nil else { return }
        do {
            try encoder.encode(record).write(to: url(for: record.id), options: .atomic)
            if isLoading { changedDuringLoad.insert(record.id) }
            sessions.removeAll { $0.id == record.id }
            sessions.insert(record, at: 0)
            dlog("history saved: \(record.id) (\(record.lineCount) lines)")
        } catch {
            dlog("history save failed: \(error.localizedDescription)")
        }
    }

    func delete(_ record: SessionRecord) {
        if isLoading { changedDuringLoad.insert(record.id) }
        do { try FileManager.default.removeItem(at: url(for: record.id)) }
        catch { dlog("history delete failed: \(error.localizedDescription)") }
        if let rec = recordingURL(for: record) {
            do { try FileManager.default.removeItem(at: rec) }
            catch { dlog("recording delete failed: \(error.localizedDescription)") }
        }
        sessions.removeAll { $0.id == record.id }
    }

    /// 匯出成 Markdown 文字（給「儲存逐字稿」與複製用）。
    static func markdown(_ r: SessionRecord) -> String {
        let f = SessionRecord.timeFormatter
        var out = trf("transcript.title", r.title) + "\n" + trf("transcript.meta", r.source.label, r.target.name) + "\n\n"
        for p in r.panes where !p.lines.isEmpty {
            let title = p.language.translation == p.target.translation
                ? trf("pane.title.transcriptOnly", p.language.name)
                : "\(p.language.name) → \(p.target.name)"
            out += "## \(title)\n\n"
            for l in p.lines {
                out += "[\(f.string(from: l.time))]"
                if r.source == .mixed { out += "（\(l.source.label)）" }
                out += " \(l.original)\n"
                if let t = l.translated { out += "    → \(t)\n" }
            }
            out += "\n"
        }
        return out
    }
}
