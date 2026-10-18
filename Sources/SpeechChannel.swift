import AVFoundation
import CoreMedia
import Speech

/// 辨識結果中的一段（對應 AttributedString 的一個 run），有自己的音訊時間範圍。
struct SpeechSegment {
    let text: String
    let range: CMTimeRange
    let confidence: Double
}

/// 一筆辨識結果。confidence < 0 表示這個 locale 沒有提供信心值。
struct SpeechResult {
    let text: String
    let isFinal: Bool
    let confidence: Double
    let range: CMTimeRange
    let segments: [SpeechSegment]
}

enum SpeechEvent {
    case status(String)
    case result(SpeechResult)
    case error(String)
}

enum SpeechError: LocalizedError {
    case unsupportedLocale(String)
    case noAudioFormat
    case modelDownload(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): return trf("err.unsupportedLocale", LanguageMap.displayName(forSpeechLocale: id))
        case .noAudioFormat: return tr("err.noAudioFormat")
        case .modelDownload(let e): return trf("err.modelDownload", e.localizedDescription)
        }
    }
}

/// 一條 SpeechAnalyzer 辨識通道：餵 16 kHz 單聲道 Float32，吐出草稿（volatile）與定稿（final）。
/// 草稿是「這句還沒說完」的即時猜測，會被同一句的下一次草稿或最後的定稿取代。
@available(macOS 26.0, *)
final class SpeechChannel: @unchecked Sendable {
    let locale: Locale
    /// `.fastResults`：草稿出得更快、但更不準。沒開的話草稿會好幾秒一批吐出來，不像即時。
    let fastResults: Bool
    var onEvent: ((SpeechEvent) -> Void)?

    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?

    private final class Once: @unchecked Sendable { var done = false }

    init(locale: Locale, fastResults: Bool = true) {
        self.locale = locale
        self.fastResults = fastResults
    }

    private func emit(_ e: SpeechEvent) { onEvent?(e) }

    func start() async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechError.unsupportedLocale(locale.identifier)
        }
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if fastResults { reporting.insert(.fastResults) }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: reporting,
            attributeOptions: [.transcriptionConfidence, .audioTimeRange])

        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }) {
            emit(.status(trf("status.downloading", LanguageMap.displayName(forSpeechLocale: supported.identifier))))
            do {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await req.downloadAndInstall()
                }
            } catch {
                throw SpeechError.modelDownload(error)
            }
        }

        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat) else {
            throw SpeechError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: fmt)

        // 有界佇列：擷取端永不阻塞，真塞住時丟最舊的，而不是把延遲無限拉長。
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(4000))
        lock.withLock {
            self.analyzer = analyzer
            self.continuation = cont
            self.analyzerFormat = fmt
            self.converter = fmt == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: fmt)
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let conf = Self.meanConfidence(result.text)
                    let segments = result.isFinal ? Self.segments(result.text, fallback: result.range) : []
                    self?.emit(.result(SpeechResult(text: text, isFinal: result.isFinal, confidence: conf,
                                                    range: result.range, segments: segments)))
                }
            } catch is CancellationError {
            } catch {
                self?.emit(.error(error.localizedDescription))
            }
        }
        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch is CancellationError {
            } catch {
                self?.emit(.error(error.localizedDescription))
            }
        }
    }

    private static func segments(_ text: AttributedString, fallback: CMTimeRange) -> [SpeechSegment] {
        text.runs.map { run in
            SpeechSegment(text: String(text[run.range].characters),
                          range: run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? fallback,
                          confidence: run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] ?? -1)
        }
    }

    /// AttributedString 各段的平均信心值；沒有信心值屬性時回傳 -1。
    private static func meanConfidence(_ text: AttributedString) -> Double {
        var sum = 0.0, n = 0
        for run in text.runs {
            if let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                sum += c
                n += 1
            }
        }
        return n == 0 ? -1 : sum / Double(n)
    }

    /// 16 kHz 單聲道 Float32。可從任何執行緒呼叫。
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let (cont, conv, fmt) = lock.withLock { (continuation, converter, analyzerFormat) }
        guard let cont, let fmt,
              let src = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = src.floatChannelData else { return }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { dst[0].update(from: $0.baseAddress!, count: samples.count) }

        guard let conv else {
            cont.yield(AnalyzerInput(buffer: src))
            return
        }
        let ratio = fmt.sampleRate / inputFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 32) else { return }
        let once = Once()
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if once.done { status.pointee = .noDataNow; return nil }
            once.done = true
            status.pointee = .haveData
            return src
        }
        guard error == nil, out.frameLength > 0 else { return }
        cont.yield(AnalyzerInput(buffer: out))
    }

    func stop() async {
        let (cont, analyzer, results, analyzerTask) = lock.withLock {
            defer { continuation = nil; self.analyzer = nil; resultsTask = nil; self.analyzerTask = nil }
            return (continuation, self.analyzer, resultsTask, self.analyzerTask)
        }
        cont?.finish()
        if let analyzer {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { await analyzer.cancelAndFinishNow() }
        }
        await analyzerTask?.value
        results?.cancel()
    }
}
