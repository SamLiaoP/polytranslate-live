import Accelerate
import AVFoundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case noMicrophone
    case microphoneDenied
    case screenRecordingDenied(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return tr("err.noDisplay")
        case .noMicrophone: return tr("err.noMic")
        case .microphoneDenied: return tr("err.micDenied")
        case .screenRecordingDenied(let detail): return trf("err.screenDenied", detail)
        }
    }
}

/// 把任意格式的 PCM buffer 轉成 16 kHz 單聲道 Float32。
/// 重採樣器有狀態（濾波器尾巴），所以每個來源各用一個實例，不要共用。
final class Resampler {
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var rateConverter: AVAudioConverter?
    private var rateConverterSrcRate: Double = 0
    private var floatConverter: AVAudioConverter?
    private var floatConverterSrc: AVAudioFormat?
    // 每個 callback 都 new buffer 很浪費（系統聲音一秒二十幾次），容量夠就重用。
    private var floatBuf: AVAudioPCMBuffer?
    private var monoBuf: AVAudioPCMBuffer?
    private var outBuf: AVAudioPCMBuffer?

    private final class Once: @unchecked Sendable { var done = false }

    private func reuse(_ slot: inout AVAudioPCMBuffer?, format: AVAudioFormat, capacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let b = slot, b.format == format, b.frameCapacity >= capacity { return b }
        slot = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        return slot
    }

    func process(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let fmt = buffer.format

        // 1. 先統一成 Float32 非交錯。
        var src = buffer
        if fmt.commonFormat != .pcmFormatFloat32 || fmt.isInterleaved {
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate,
                                        channels: fmt.channelCount, interleaved: false) else { return nil }
            if floatConverterSrc != fmt {
                floatConverter = AVAudioConverter(from: fmt, to: f)
                floatConverterSrc = fmt
            }
            guard let conv = floatConverter,
                  let out = reuse(&floatBuf, format: f, capacity: buffer.frameLength) else { return nil }
            do { try conv.convert(to: out, from: buffer) } catch { return nil }
            src = out
        }

        // 2. 混成單聲道（平均各聲道；AVAudioConverter 直接多→單有時會靜音填零，所以自己做）。
        let ch = Int(src.format.channelCount)
        guard let data = src.floatChannelData,
              let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false),
              let mono = reuse(&monoBuf, format: monoFmt, capacity: AVAudioFrameCount(frames)) else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        let dst = mono.floatChannelData![0]
        if ch == 1 {
            dst.update(from: data[0], count: frames)
        } else {
            dst.update(from: data[0], count: frames)
            for c in 1..<ch { vDSP_vadd(dst, 1, data[c], 1, dst, 1, vDSP_Length(frames)) }
            var scale = 1 / Float(ch)
            vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frames))
        }

        // 3. 重採樣到 16 kHz。
        if fmt.sampleRate == 16_000 {
            return Array(UnsafeBufferPointer(start: dst, count: frames))
        }
        if rateConverter == nil || rateConverterSrcRate != fmt.sampleRate {
            rateConverter = AVAudioConverter(from: monoFmt, to: outFormat)
            rateConverterSrcRate = fmt.sampleRate
        }
        guard let conv = rateConverter else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * 16_000 / fmt.sampleRate) + 32
        guard let out = reuse(&outBuf, format: outFormat, capacity: capacity) else { return nil }
        out.frameLength = 0
        let once = Once()
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if once.done { status.pointee = .noDataNow; return nil }
            once.done = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, out.frameLength > 0, let o = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: o[0], count: Int(out.frameLength)))
    }
}

/// 系統聲音：ScreenCaptureKit。不需要 BlackHole 之類的虛擬音效卡，
/// 但需要「螢幕與系統音訊錄製」權限。
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "polytranslate.system-audio")
    private let resampler = Resampler()
    var onSamples: (([Float]) -> Void)?
    var onError: ((Error) -> Void)?

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.screenRecordingDenied(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // 直接要辨識器要的格式，Resampler 就只剩複製一份；不用 48 kHz 立體聲再自己降。
        config.sampleRate = 16_000
        config.channelCount = 1
        // 只要聲音，影像縮到最小、每秒一張。
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        do {
            try await s.startCapture()
        } catch {
            throw CaptureError.screenRecordingDenied(error.localizedDescription)
        }
        stream = s
    }

    func stop() async {
        let s = stream
        stream = nil
        try? await s?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = sampleBuffer.toPCMBuffer(),
              let samples = resampler.process(pcm) else { return }
        onSamples?(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

/// 麥克風：AVAudioEngine 預設輸入裝置。
/// 換裝置（接上 AirPods、拔耳機）時 engine 會停掉並發 configurationChange 通知，要重裝 tap 再啟動，
/// 不然麥克風就無聲了但介面還顯示聆聽中。
final class MicrophoneCapture {
    private var engine: AVAudioEngine?
    private let resampler = Resampler()
    private var observer: NSObjectProtocol?
    var onSamples: (([Float]) -> Void)?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        let engine = AVAudioEngine()
        try attachAndStart(engine)
        self.engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            self?.restart()
        }
    }

    private func attachAndStart(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw CaptureError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buffer, _ in
            guard let self, let samples = self.resampler.process(buffer) else { return }
            self.onSamples?(samples)
        }
        engine.prepare()
        try engine.start()
        dlog("mic: \(Int(fmt.sampleRate)) Hz × \(fmt.channelCount) ch")
    }

    private func restart() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try attachAndStart(engine)
            dlog("mic: input device changed, restarted")
        } catch {
            dlog("mic: restart after device change failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

/// 管理兩個來源，把音訊分送給訂閱者。訂閱者的 callback 在擷取執行緒上被呼叫，
/// 只能做「丟進佇列」這種不阻塞的事。
final class AudioHub {
    private var system: SystemAudioCapture?
    private var mic: MicrophoneCapture?
    private let lock = NSLock()
    private var subscribers: [UUID: (kind: CaptureKind, callback: ([Float]) -> Void)] = [:]
    var onSystemAudioError: ((Error) -> Void)?

    func subscribe(_ kind: CaptureKind, _ callback: @escaping ([Float]) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { subscribers[id] = (kind, callback) }
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.withLock { _ = subscribers.removeValue(forKey: id) }
    }

    /// 測試模式用：從外部直接灌音訊（例如讀 wav 檔）。
    func inject(_ kind: CaptureKind, _ samples: [Float]) { fanOut(kind, samples) }

    private func fanOut(_ kind: CaptureKind, _ samples: [Float]) {
        let targets = lock.withLock { subscribers.values.filter { $0.kind == kind }.map(\.callback) }
        for cb in targets { cb(samples) }
    }

    /// 啟動需要的來源。失敗就丟錯，由上層顯示。
    func start(kinds: Set<CaptureKind>) async throws {
        if kinds.contains(.microphone), mic == nil {
            guard await MicrophoneCapture.requestPermission() else { throw CaptureError.microphoneDenied }
            let m = MicrophoneCapture()
            m.onSamples = { [weak self] in self?.fanOut(.microphone, $0) }
            try m.start()
            mic = m
        }
        if kinds.contains(.system), system == nil {
            let s = SystemAudioCapture()
            s.onSamples = { [weak self] in self?.fanOut(.system, $0) }
            s.onError = { [weak self] in self?.onSystemAudioError?($0) }
            try await s.start()
            system = s
        }
    }

    func stopAll() async {
        mic?.stop()
        mic = nil
        await system?.stop()
        system = nil
    }
}

extension CMSampleBuffer {
    /// 把 ScreenCaptureKit 給的音訊 sample buffer 包成 AVAudioPCMBuffer。
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
