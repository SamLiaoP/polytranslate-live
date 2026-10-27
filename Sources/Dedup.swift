import Foundation

/// 混合模式去重：同一句話常常同時被「系統音訊」和「麥克風」聽到（耳機漏音、耳麥線路串音、
/// 外放時麥克風收到喇叭聲），兩條來源會各吐出一句幾乎一樣的定稿。這裡判斷兩段文字是不是同一句。
enum Dedup {
    /// 幾秒內的另一來源定稿才算候選（兩條辨識 lane 的斷句時間點可能差好幾秒）。
    static let windowSeconds: TimeInterval = 20
    /// 相似度門檻（0–1）。
    static let threshold = 0.8
    /// 「包含」判定至少要這麼長的正規化字數，避免 "OK" 這種短句被誤殺。
    static let minContainLength = 12

    /// 去掉大小寫、標點、空白，只留字母／數字／漢字等，讓「Hello, world!」和「hello world」相等。
    static func normalize(_ s: String) -> [Character] {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) }
    }

    /// 兩段文字是否同一句：正規化後相似度 ≥ threshold，或較短的那段（夠長時）整段包含在較長的那段裡
    /// （兩條 lane 斷句不同時會一條長、一條拆成兩短）。
    static func isDuplicate(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        if short.count >= minContainLength, contains(long, short) { return true }
        return similarity(x, y) >= threshold
    }

    /// 1 − 編輯距離／較長長度。
    static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return 0 }
        // 長度差太多就不可能相似，省掉 O(n·m)。
        if Double(min(n, m)) / Double(max(n, m)) < threshold { return 0 }
        var prev = Array(0...m), cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[m]) / Double(max(n, m))
    }

    private static func contains(_ hay: [Character], _ needle: [Character]) -> Bool {
        guard needle.count <= hay.count else { return false }
        if needle.count == hay.count { return hay == needle }
        for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
            if Array(hay[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}
