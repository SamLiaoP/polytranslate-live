import Foundation

/// 簡單的檔案日誌：~/Library/Logs/PolyTranslateLive.log。沒有 Xcode 也能看 App 內部發生什麼事。
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()
    private let queue = DispatchQueue(label: "polytranslate.log")
    private let handle: FileHandle?
    let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("PolyTranslateLive.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
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

func dlog(_ message: @autoclosure () -> String) { DebugLog.shared.log(message()) }
