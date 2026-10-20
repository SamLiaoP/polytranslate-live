import Accelerate
import AVFoundation
import Foundation

/// 把 `AudioHub` 分送的 16 kHz 單聲道樣本寫成 AAC（.m4a），一場 session 一個檔。
///
/// 混合來源時系統聲音和麥克風來自兩條擷取執行緒，節奏不同、buffer 大小也不同，
/// 直接相加會錯位。所以每一路先進各自的 FIFO，再由固定節拍（250 ms）的 timer
/// 從每路取相同長度相加後寫檔；某一路暫時沒資料就補靜音，堆太多（> 2 秒）就丟掉最舊的。
/// 單一來源也走同一條路，少一種狀況要維護。
final class SessionRecorder: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private static let tick = 0.25
    private static let tickFrames = Int(sampleRate * tick)
    private static let maxQueued = Int(sampleRate * 2)

    let url: URL
    private let queue = DispatchQueue(label: "polytranslate.recorder")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var sources: [(kind: CaptureKind, queue: [Float])] = []
    private var timer: DispatchSourceTimer?
    private var subscriptions: [UUID] = []
    private weak var hub: AudioHub?
    private var mixBuf: AVAudioPCMBuffer?
    private var frames: Int64 = 0
    private var padded = 0
    private var dropped = 0

    init(url: URL) { self.url = url }

    func start(hub: AudioHub, kinds: [CaptureKind]) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,     // 語音夠用，約 14 MB／小時
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        sources = kinds.map { ($0, []) }
        self.hub = hub
        subscriptions = kinds.map { kind in
            hub.subscribe(kind) { [weak self] samples in self?.enqueue(kind, samples) }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 先累積兩個 tick 再開始取，讓兩路都有緩衝，不會一開始就補靜音。
        t.schedule(deadline: .now() + Self.tick * 2, repeating: Self.tick)
        t.setEventHandler { [weak self] in self?.pump(drain: false) }
        t.resume()
        timer = t
        dlog("recording started: \(url.lastPathComponent) (\(kinds.map(\.rawValue)))")
    }

    /// 擷取執行緒上被呼叫，只把樣本丟進佇列。
    private func enqueue(_ kind: CaptureKind, _ samples: [Float]) {
        queue.async { [self] in
            guard let i = sources.firstIndex(where: { $0.kind == kind }) else { return }
            sources[i].queue.append(contentsOf: samples)
            let excess = sources[i].queue.count - Self.maxQueued
            if excess > 0 {
                sources[i].queue.removeFirst(excess)
                dropped += excess
            }
        }
    }

    /// 從每一路取 `tickFrames` 相加寫檔；`drain` 時把剩下的全寫掉。
    private func pump(drain: Bool) {
        guard let file else { return }
        let n = drain ? (sources.map(\.queue.count).max() ?? 0) : Self.tickFrames
        guard n > 0 else { return }
        if mixBuf == nil || mixBuf!.frameCapacity < AVAudioFrameCount(n) {
            mixBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))
        }
        guard let buf = mixBuf, let out = buf.floatChannelData?[0] else { return }
        vDSP_vclr(out, 1, vDSP_Length(n))
        for i in sources.indices {
            let take = min(n, sources[i].queue.count)
            if take > 0 {
                sources[i].queue.withUnsafeBufferPointer { p in
                    vDSP_vadd(out, 1, p.baseAddress!, 1, out, 1, vDSP_Length(take))
                }
                sources[i].queue.removeFirst(take)
            }
            if !drain, take < n { padded += n - take }
        }
        var lo: Float = -1, hi: Float = 1
        vDSP_vclip(out, 1, &lo, &hi, out, 1, vDSP_Length(n))   // 兩路相加可能超過 ±1
        buf.frameLength = AVAudioFrameCount(n)
        do {
            try file.write(from: buf)
            frames += Int64(n)
        } catch {
            dlog("recording write failed: \(error.localizedDescription); recording stopped")
            self.file = nil
        }
    }

    /// 收掉訂閱、寫完剩餘樣本、關檔。回傳檔案與長度（秒）。
    func stop() async -> (url: URL, seconds: Double) {
        if let hub { for id in subscriptions { hub.unsubscribe(id) } }
        subscriptions = []
        return await withCheckedContinuation { cont in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                pump(drain: true)
                file = nil   // AVAudioFile 在釋放時才把 AAC 容器收尾
                let seconds = Double(frames) / Self.sampleRate
                dlog("recording stopped: \(String(format: "%.1f", seconds))s, padded \(padded) frames, dropped \(dropped)")
                cont.resume(returning: (url, seconds))
            }
        }
    }
}
