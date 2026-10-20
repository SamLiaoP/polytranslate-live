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

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PolyTranslateLive/history", isDirectory: true)
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
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
    func load() {
        let dir = self.dir, decoder = self.decoder
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> [SessionRecord] in
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                return files
                    .filter { $0.pathExtension == "json" }
                    .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
                    .sorted { $0.startedAt > $1.startedAt }
            }.value
            guard let self else { return }
            // 讀檔期間可能已經存了新的一筆，別把它蓋掉。
            let fresh = sessions.filter { s in !loaded.contains { $0.id == s.id } }
            sessions = (fresh + loaded).sorted { $0.startedAt > $1.startedAt }
            dlog("history loaded: \(sessions.count) sessions")
        }
    }

    func save(_ record: SessionRecord) {
        guard record.lineCount > 0 || record.recording != nil else { return }
        do {
            try encoder.encode(record).write(to: url(for: record.id), options: .atomic)
            sessions.removeAll { $0.id == record.id }
            sessions.insert(record, at: 0)
            dlog("history saved: \(record.id) (\(record.lineCount) lines)")
        } catch {
            dlog("history save failed: \(error.localizedDescription)")
        }
    }

    func delete(_ record: SessionRecord) {
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
