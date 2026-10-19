import Foundation

/// 簡單的檔案日誌：~/Library/Logs/PolyTranslateLive.log。沒有 Xcode 也能看 App 內部發生什麼事。
///
/// 預設只記「事件」（通道啟動、仲裁決定、翻譯成功失敗），不記講了什麼。
/// 要連內容一起記（除錯辨識／仲裁用）：啟動參數加 `--verbose`，或測試模式 `--test-wav`。
/// 檔案超過 5 MB 時啟動會輪替成 .1，避免無限長大。
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()
    private let queue = DispatchQueue(label: "polytranslate.log")
    private var handle: FileHandle?
    let url: URL
    /// 是否記錄辨識／翻譯的文字內容。
    nonisolated(unsafe) var verbose = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("--test-wav")

    private static let maxBytes: UInt64 = 5 * 1024 * 1024

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("PolyTranslateLive.log")
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64), size > Self.maxBytes {
            let old = dir.appendingPathComponent("PolyTranslateLive.log.1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func log(_ message: @autoclosure () -> String) {
        let line = "\(Self.stamp()) \(message())\n"
        queue.async { [handle] in
            if let data = line.data(using: .utf8) { handle?.write(data) }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static func stamp() -> String { formatter.string(from: Date()) }
}

/// 事件日誌（不含使用者內容）。
func dlog(_ message: @autoclosure () -> String) { DebugLog.shared.log(message()) }

/// 內容日誌：只有 verbose 模式才寫（會包含辨識出的文字與譯文）。
func dlogv(_ message: @autoclosure () -> String) {
    guard DebugLog.shared.verbose else { return }
    DebugLog.shared.log(message())
}
