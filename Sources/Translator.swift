import Foundation
import Translation

enum TranslatorError: LocalizedError {
    case languagePackMissing(source: String, target: String)
    case unsupportedPair(source: String, target: String)
    case llmNotConfigured
    case llmHTTP(Int, String)
    case llmBadResponse

    var errorDescription: String? {
        switch self {
        case .languagePackMissing(let s, let t):
            return trf("err.packMissing", LanguageMap.displayName(forTarget: s), LanguageMap.displayName(forTarget: t))
        case .unsupportedPair(let s, let t):
            return trf("err.unsupportedPair", LanguageMap.displayName(forTarget: s), LanguageMap.displayName(forTarget: t))
        case .llmNotConfigured:
            return tr("err.llmNotConfigured")
        case .llmHTTP(let code, let body):
            return trf("err.llmHTTP", code, String(body.prefix(200)))
        case .llmBadResponse:
            return tr("err.llmBadResponse")
        }
    }
}

/// Apple Translation.framework，裝置端、低延遲（通常 <100 ms）。
/// 用 macOS 26.4 新增的 `TranslationSession(installedSource:target:preferredStrategy:)`，
/// 不必綁 SwiftUI 的 `.translationTask`。
@available(macOS 26.4, *)
actor AppleTranslator {
    private struct Entry {
        var session: TranslationSession
        var strategy: TranslationSession.Strategy
    }
    private var sessions: [String: Entry] = [:]
    private let availability = LanguageAvailability()
    /// 哪些語言對退回了 highFidelity（沒裝離線低延遲語言包）。UI 用來提示使用者。
    private(set) var fallbackPairs: Set<String> = []

    func status(from source: String, to target: String) async -> LanguageAvailability.Status {
        await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    }

    func isUsingFallback(from source: String, to target: String) -> Bool {
        fallbackPairs.contains("\(source)|\(target)")
    }

    /// 語言包剛裝好：丟掉快取的 session，下一句重新用低延遲模式。
    /// 不這樣做的話，退回 highFidelity 的 session 會一直用到 App 重開。
    func invalidate(from source: String, to target: String) {
        let key = "\(source)|\(target)"
        sessions.removeValue(forKey: key)
        fallbackPairs.remove(key)
        dlog("translator: session \(key) invalidated")
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let key = "\(source)|\(target)"
        let src = Locale.Language(identifier: source)
        let tgt = Locale.Language(identifier: target)

        if sessions[key] == nil {
            switch await availability.status(from: src, to: tgt) {
            case .installed, .supported:
                break
            case .unsupported:
                throw TranslatorError.unsupportedPair(source: source, target: target)
            @unknown default:
                throw TranslatorError.unsupportedPair(source: source, target: target)
            }
            // actor 在 await 期間可重入：另一筆翻譯可能已經建好了，別重複建。
            if sessions[key] == nil {
                sessions[key] = Entry(session: TranslationSession(installedSource: src, target: tgt, preferredStrategy: .lowLatency),
                                      strategy: .lowLatency)
            }
        }
        guard let entry = sessions[key] else { throw TranslatorError.unsupportedPair(source: source, target: target) }

        do {
            return try await Self.run(entry.session, text)
        } catch let error as TranslationError where entry.strategy == .lowLatency {
            // 離線低延遲語言包沒裝（系統設定 › 一般 › 語言與地區 › 翻譯語言）。
            // 退回 highFidelity：實測這台機器上 200–400 ms，仍然可用，但會提示使用者去裝語言包。
            dlog("translator: lowLatency \(key) failed (\(error.localizedDescription)); falling back to highFidelity")
            let fallback = Entry(session: TranslationSession(installedSource: src, target: tgt, preferredStrategy: .highFidelity),
                                 strategy: .highFidelity)
            sessions[key] = fallback
            fallbackPairs.insert(key)
            do {
                return try await Self.run(fallback.session, text)
            } catch {
                sessions.removeValue(forKey: key)
                dlog("translator: highFidelity \(key) failed too: \(error.localizedDescription)")
                // 語言包真的沒裝才報「請裝語言包」；已經裝了卻失敗（網路、暫時性錯誤）就把原始錯誤丟回去。
                if await availability.status(from: src, to: tgt) == .installed { throw error }
                throw TranslatorError.languagePackMissing(source: source, target: target)
            }
        } catch {
            sessions.removeValue(forKey: key)   // session 壞了就下次重建
            throw error
        }
    }

    private static func run(_ session: TranslationSession, _ text: String) async throws -> String {
        let result = try await session.translate(text)
        return result.targetText.replacingOccurrences(of: "\n", with: " ")
    }
}

/// OpenAI 相容的 chat/completions API。慢一點（0.5–2 秒），但能帶術語表與情境，
/// 對專有名詞、產業用語的準確度好很多。這就是 Transync「AI 助手」做的事。
actor LLMTranslator {
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        return URLSession(configuration: cfg)
    }()

    func translate(_ text: String, from source: String, to target: String,
                   config: LLMConfig, recentContext: [String]) async throws -> String {
        guard !config.baseURL.isEmpty, !config.model.isEmpty else { throw TranslatorError.llmNotConfigured }
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw TranslatorError.llmNotConfigured }

        var system = """
        You are a professional simultaneous interpreter. Translate the user's speech transcript from \
        \(LanguageMap.englishName(source)) into \(LanguageMap.englishName(target)). \
        Output ONLY the translation, no quotes, no explanations. Keep it concise and natural for live subtitles. \
        The transcript comes from speech recognition and may contain minor errors; translate the intended meaning.
        """
        let glossary = config.glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !glossary.isEmpty {
            system += "\n\nGlossary / preferred terms (follow strictly):\n" + glossary
        }
        let context = config.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            system += "\n\nContext about this conversation:\n" + context
        }
        if !recentContext.isEmpty {
            system += "\n\nPrevious sentences (for context only, do not translate them):\n" + recentContext.joined(separator: "\n")
        }

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw TranslatorError.llmHTTP(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslatorError.llmBadResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 統一入口：依設定選後端。
@MainActor
final class TranslatorHub {
    private let settings: AppSettings
    private let apple = AppleTranslator()
    private let llm = LLMTranslator()

    init(settings: AppSettings) {
        self.settings = settings
    }

    func appleUsingFallback(from speechLocale: String, to target: String) async -> Bool {
        let source = LanguageMap.translationLanguage(forSpeechLocale: speechLocale)
        return await apple.isUsingFallback(from: source, to: target)
    }

    /// 語言包下載完成後呼叫，讓這一對語言下一句就改用離線低延遲模式。
    func appleLanguagePackInstalled(from speechLocale: String, to target: String) async {
        let source = LanguageMap.translationLanguage(forSpeechLocale: speechLocale)
        await apple.invalidate(from: source, to: target)
    }

    func appleStatus(from speechLocale: String, to target: String) async -> LanguageAvailability.Status? {
        let source = LanguageMap.translationLanguage(forSpeechLocale: speechLocale)
        return await apple.status(from: source, to: target)
    }

    func translate(_ text: String, fromSpeechLocale speechLocale: String, to target: String,
                   recentContext: [String] = []) async throws -> String {
        let source = LanguageMap.translationLanguage(forSpeechLocale: speechLocale)
        if source == target { return text }
        switch settings.data.backend {
        case .apple:
            return try await apple.translate(text, from: source, to: target)
        case .llm:
            return try await llm.translate(text, from: source, to: target,
                                           config: settings.data.llm, recentContext: recentContext)
        }
    }
}
