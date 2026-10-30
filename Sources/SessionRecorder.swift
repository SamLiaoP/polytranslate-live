import Accelerate
import AVFoundation
import Foundation

/// 把 `AudioHub` 分送的 16 kHz 單聲道樣本寫成 AAC（.m4a），一場 session 一個檔。
///
/// 混合來源時系統聲音和麥克風來自兩條擷取執行緒，節奏不同、buffer 大小也不同，
/// 直接相加會錯位。所以每一路先進各自的 FIFO，再由固定節拍（250 ms）的 timer
/// 從每路取相同長度相加後寫檔；某一路暫時沒資料就補靜音，堆太多（> 2 秒）就丟掉最舊的。
/// 單一來源也走同一條路，少一種狀況要維護。
///
/// 寫檔用 AVAssetWriter 的分段模式（movie fragments）：每 `fragmentSeconds` 秒把索引寫進檔案一次，
/// 所以 App 被強制結束、當機或斷電時，檔案仍播得到最後一個分段，最多只掉幾秒。
/// 以前用 AVAudioFile，索引要等正常關檔才寫，一被強制結束整個檔就打不開（2026-10-28 這樣掉了 95 分鐘）。
final class SessionRecorder: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let defaultFragmentSeconds = 10.0
    private static let tick = 0.25
    private static let tickFrames = Int(sampleRate * tick)
    private static let maxQueued = Int(sampleRate * 2)

    enum RecorderError: LocalizedError {
        case cannotStart(String)
        var errorDescription: String? {
            switch self { case .cannotStart(let why): return why }
        }
    }

    let url: URL
    private let fragmentSeconds: Double
    private let queue = DispatchQueue(label: "polytranslate.recorder")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sources: [(kind: CaptureKind, queue: [Float])] = []
    private var timer: DispatchSourceTimer?
    private var subscriptions: [UUID] = []
    private weak var hub: AudioHub?
    private var mixBuf: AVAudioPCMBuffer?
    private var frames: Int64 = 0
    private var padded = 0
    private var dropped = 0

    init(url: URL, fragmentSeconds: Double = SessionRecorder.defaultFragmentSeconds) {
        self.url = url
        self.fragmentSeconds = fragmentSeconds
    }

    func start(hub: AudioHub, kinds: [CaptureKind]) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,     // 語音夠用，約 14 MB／小時
        ]
        let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
        w.movieFragmentInterval = CMTime(seconds: fragmentSeconds, preferredTimescale: 600)
        let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format.formatDescription)
        inp.expectsMediaDataInRealTime = true
        guard w.canAdd(inp) else { throw RecorderError.cannotStart("AVAssetWriter rejected the audio input") }
        w.add(inp)
        guard w.startWriting() else {
            throw RecorderError.cannotStart(w.error?.localizedDescription ?? "AVAssetWriter.startWriting failed")
        }
        w.startSession(atSourceTime: .zero)
        writer = w
        input = inp
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
        dlog("recording started: \(url.lastPathComponent) (\(kinds.map(\.rawValue))), fragment every \(Int(fragmentSeconds)) s")
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
        guard let writer, let input, writer.status == .writing else { return }
        let n = drain ? (sources.map(\.queue.count).max() ?? 0) : Self.tickFrames
        guard n > 0 else { return }
        // 編碼器還沒消化完上一批就先不取，樣本留在佇列裡（佇列滿了才算丟掉）；收尾時多等一下。
        var waited = 0
        while !input.isReadyForMoreMediaData {
            guard drain, waited < 100 else { return }
            usleep(10_000)
            waited += 1
        }
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
        guard let sample = makeSampleBuffer(buf) else {
            fail("cannot wrap PCM into a sample buffer")
            return
        }
        if input.append(sample) {
            frames += Int64(n)
        } else {
            fail(writer.error?.localizedDescription ?? "AVAssetWriterInput.append failed")
        }
    }

    /// 寫檔失敗就停：已寫的分段仍在檔案裡，之後 stop() 只是不再收尾。
    private func fail(_ why: String) {
        dlog("recording write failed: \(why); recording stopped")
        writer = nil
        input = nil
    }

    /// 把 PCM buffer 包成帶時間戳的 CMSampleBuffer（AVAssetWriter 只吃這個）。資料會被複製，所以 `mixBuf` 可重複使用。
    private func makeSampleBuffer(_ buf: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let scale = Int32(Self.sampleRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: scale),
                                        presentationTimeStamp: CMTime(value: frames, timescale: scale),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                          makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: format.formatDescription,
                                          sampleCount: CMItemCount(buf.frameLength),
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                                blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                flags: 0, bufferList: buf.audioBufferList)
        return status == noErr ? sample : nil
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
                let seconds = Double(frames) / Self.sampleRate
                let w = writer, inp = input
                writer = nil
                input = nil
                let url = self.url
                let finish = { [padded, dropped] in
                    dlog("recording stopped: \(String(format: "%.1f", seconds))s, padded \(padded) frames, dropped \(dropped)")
                    cont.resume(returning: (url, seconds))
                }
                guard let w, let inp, w.status == .writing else { finish(); return }
                inp.markAsFinished()
                w.finishWriting {
                    if w.status != .completed {
                        dlog("recording finish failed: \(w.error?.localizedDescription ?? "status \(w.status.rawValue)")")
                    }
                    finish()
                }
            }
        }
    }
}
