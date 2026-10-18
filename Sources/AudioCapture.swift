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

    private final class Once: @unchecked Sendable { var done = false }

    func process(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let fmt = buffer.format

        // 1. 先統一成 Float32 非交錯。
        var floatBuf = buffer
        if fmt.commonFormat != .pcmFormatFloat32 || fmt.isInterleaved {
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate,
                                        channels: fmt.channelCount, interleaved: false) else { return nil }
            if floatConverterSrc != fmt {
                floatConverter = AVAudioConverter(from: fmt, to: f)
                floatConverterSrc = fmt
            }
            guard let conv = floatConverter,
                  let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: buffer.frameLength) else { return nil }
            do { try conv.convert(to: out, from: buffer) } catch { return nil }
            floatBuf = out
        }

        // 2. 混成單聲道（平均各聲道；AVAudioConverter 直接多→單有時會靜音填零，所以自己做）。
        let ch = Int(floatBuf.format.channelCount)
        guard let data = floatBuf.floatChannelData,
              let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        let dst = mono.floatChannelData![0]
        if ch == 1 {
            dst.update(from: data[0], count: frames)
        } else {
            let scale = 1 / Float(ch)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += data[c][i] }
                dst[i] = s * scale
            }
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
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
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
        config.sampleRate = 48_000
        config.channelCount = 2
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
final class MicrophoneCapture {
    private var engine: AVAudioEngine?
    private let resampler = Resampler()
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
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw CaptureError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buffer, _ in
            guard let self, let samples = self.resampler.process(buffer) else { return }
            self.onSamples?(samples)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
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
