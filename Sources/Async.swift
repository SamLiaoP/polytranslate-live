import Foundation

/// 跑一段 async 工作，超過 `seconds` 就放棄（回傳 nil 並取消那段工作）。
/// 用在「停止辨識」「結束 App」這種不能無限等的地方。
func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
