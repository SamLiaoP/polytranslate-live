import Foundation

/// 實際的擷取來源（麥克風 / 系統聲音）。
enum CaptureKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case system
    case microphone

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return tr("source.system")
        case .microphone: return tr("source.mic")
        }
    }
    var symbol: String {
        switch self {
        case .system: return "speaker.wave.2.fill"
        case .microphone: return "mic.fill"
        }
    }
}

/// 使用者選的聲音來源。混合 = 兩個來源各跑一組辨識器，結果合流。
enum AudioSourceKind: String, Codable, CaseIterable, Identifiable {
    case system
    case microphone
    case mixed

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return tr("source.system")
        case .microphone: return tr("source.mic")
        case .mixed: return tr("source.mixed")
        }
    }
    var shortLabel: String {
        switch self {
        case .system: return tr("source.system")
        case .microphone: return tr("source.mic")
        case .mixed: return tr("source.mixed.short")
        }
    }
    var symbol: String {
        switch self {
        case .system: return "speaker.wave.2.fill"
        case .microphone: return "mic.fill"
        case .mixed: return "waveform"
        }
    }
    var captures: [CaptureKind] {
        switch self {
        case .system: return [.system]
        case .microphone: return [.microphone]
        case .mixed: return [.system, .microphone]
        }
    }
}

/// 文字系統，用來在兩個語言的辨識結果之間做合理性檢查。
enum Script {
    case han, latin, kana, hangul, other
}

/// 一種可選的語言：對應的語音辨識 locale 與翻譯語言代碼。
struct Language: Identifiable, Hashable, Codable {
    let id: String            // 例如 "zh-Hant"、"en"
    let nativeName: String    // 該語言自己的寫法，例如 "日本語"
    let speechLocale: String  // SpeechTranscriber locale，例如 "zh_TW"
    let translation: String   // Translation.framework 語言代碼，例如 "zh-Hant"
    let scriptKind: String    // Script 的字串形式，方便 Codable

    /// 介面語言裡的名稱，例如介面是中文時 "日文"。
    var name: String { tr("lang.\(id)") }

    /// 選單用：原生名稱 + 括號內介面語言的名稱，例如「日本語（日文）」、「English（英文）」。
    /// 兩者相同時（介面英文、語言英文）只顯示一個。
    var displayName: String {
        let localized = name
        return localized == nativeName ? nativeName : nativeName + trf("lang.paren", localized)
    }

    var script: Script {
        switch scriptKind {
        case "han": return .han
        case "latin": return .latin
        case "kana": return .kana
        case "hangul": return .hangul
        default: return .other
        }
    }

    /// 給語言模型 prompt 用的英文名稱。
    var englishName: String { LanguageMap.englishName(translation) }
}

enum LanguageCatalog {
    static let all: [Language] = [
        Language(id: "zh-Hant", nativeName: "繁體中文", speechLocale: "zh_TW", translation: "zh-Hant", scriptKind: "han"),
        Language(id: "zh-Hans", nativeName: "简体中文", speechLocale: "zh_CN", translation: "zh-Hans", scriptKind: "han"),
        Language(id: "yue", nativeName: "粵語", speechLocale: "yue_CN", translation: "zh-Hant", scriptKind: "han"),
        Language(id: "en", nativeName: "English", speechLocale: "en_US", translation: "en", scriptKind: "latin"),
        Language(id: "en-GB", nativeName: "English (UK)", speechLocale: "en_GB", translation: "en", scriptKind: "latin"),
        Language(id: "ja", nativeName: "日本語", speechLocale: "ja_JP", translation: "ja", scriptKind: "kana"),
        Language(id: "ko", nativeName: "한국어", speechLocale: "ko_KR", translation: "ko", scriptKind: "hangul"),
        Language(id: "fr", nativeName: "Français", speechLocale: "fr_FR", translation: "fr", scriptKind: "latin"),
        Language(id: "de", nativeName: "Deutsch", speechLocale: "de_DE", translation: "de", scriptKind: "latin"),
        Language(id: "es", nativeName: "Español", speechLocale: "es_ES", translation: "es", scriptKind: "latin"),
        Language(id: "pt-BR", nativeName: "Português (Brasil)", speechLocale: "pt_BR", translation: "pt-BR", scriptKind: "latin"),
        Language(id: "it", nativeName: "Italiano", speechLocale: "it_IT", translation: "it", scriptKind: "latin"),
    ]

    static func language(_ id: String) -> Language {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

/// 一條字幕：原文 + 之後補上的譯文。
struct SubtitleLine: Identifiable, Equatable {
    let id: Int
    var original: String
    var translated: String?
    var translationFailed = false
    let source: CaptureKind
    let timestamp: Date
}

/// 外部語言模型後端設定（OpenAI 相容 API）。介面目前沒有露出，保留給之後用。
struct LLMConfig: Codable, Equatable {
    var baseURL: String = "https://api.openai.com/v1"
    var apiKey: String = ""
    var model: String = "gpt-4o-mini"
    var glossary: String = ""
    var context: String = ""
}

enum TranslationBackendKind: String, Codable, CaseIterable, Identifiable {
    case apple
    case llm
    var id: String { rawValue }
}

/// 全域設定，存在 UserDefaults。
struct AppSettingsData: Codable, Equatable {
    /// 介面語言，預設英文。
    var uiLanguage: UILanguage = .en
    /// 所有框框共用的目標語言。
    var targetLanguage = "zh-Hant"
    /// 每個框框聽的語言，依左到右排列。預設只有一個。
    var paneLanguages: [String] = ["en"]
    var source: AudioSourceKind = .system
    var backend: TranslationBackendKind = .apple
    var llm = LLMConfig()
    var fontSize: Double = 20
    var translateDrafts = true
    var saveTranscript = true
    var sidebarVisible = false
}

@MainActor
final class AppSettings: ObservableObject {
    private static let key = "polytranslate.settings.v1"

    @Published var data: AppSettingsData {
        didSet {
            L10n.language = data.uiLanguage
            persist()
        }
    }

    init() {
        if let raw = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettingsData.self, from: raw) {
            data = decoded
        } else {
            data = AppSettingsData()
        }
        L10n.language = data.uiLanguage
    }

    private func persist() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: Self.key)
        }
    }
}

enum LanguageMap {
    private static let zhTW = Locale(identifier: "zh_TW")

    static func displayName(forSpeechLocale id: String) -> String {
        if let l = LanguageCatalog.all.first(where: { $0.speechLocale == id }) { return l.name }
        let loc = L10n.language == .en ? Locale(identifier: "en_US") : zhTW
        return loc.localizedString(forIdentifier: id) ?? id
    }

    static func displayName(forTarget code: String) -> String {
        LanguageCatalog.all.first(where: { $0.translation == code })?.name ?? code
    }

    /// 語音辨識 locale → 翻譯來源語言代碼。
    static func translationLanguage(forSpeechLocale id: String) -> String {
        if let l = LanguageCatalog.all.first(where: { $0.speechLocale == id }) { return l.translation }
        let l = id.replacingOccurrences(of: "_", with: "-")
        if l.hasPrefix("zh-TW") || l.hasPrefix("zh-HK") || l.hasPrefix("yue") { return "zh-Hant" }
        if l.hasPrefix("zh") { return "zh-Hans" }
        if l.hasPrefix("pt-BR") { return "pt-BR" }
        return String(l.prefix(2))
    }

    static func englishName(_ code: String) -> String {
        switch code {
        case "zh-Hant": return "Traditional Chinese (繁體中文, Taiwan usage)"
        case "zh-Hans": return "Simplified Chinese"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "pt-BR": return "Brazilian Portuguese"
        case "it": return "Italian"
        default: return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }
}

/// 文字系統判斷。
enum ScriptDetector {
    /// 這段文字主要屬於哪種文字系統（只看字母）。
    static func dominantScript(_ text: String) -> Script {
        var han = 0, kana = 0, hangul = 0, latin = 0
        for u in text.unicodeScalars where CharacterSet.letters.contains(u) {
            switch u.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x0041...0x024F: latin += 1
            default: break
            }
        }
        if kana > 0 { return .kana }
        if hangul > 0 { return .hangul }
        if han > 0 { return .han }
        if latin > 0 { return .latin }
        return .other
    }

    /// 剪掉開頭不屬於這個語言文字系統的部分（草稿用）。
    /// 中文通道還沒把前一句英文定稿時，草稿會是「...until thend.大家早安」，只留「大家早安」。
    /// 整段都沒有符合的字 → 回傳空字串（代表不該顯示）。
    static func trimLeadingMismatch(_ text: String, _ language: Language) -> String {
        guard language.script != .other else { return text }
        func belongs(_ u: Unicode.Scalar) -> Bool {
            switch language.script {
            case .han: return (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value)
            case .kana: return (0x3040...0x30FF).contains(u.value) || (0x4E00...0x9FFF).contains(u.value)
            case .hangul: return (0xAC00...0xD7AF).contains(u.value) || (0x1100...0x11FF).contains(u.value)
            case .latin: return (0x0041...0x024F).contains(u.value) && CharacterSet.letters.contains(u)
            case .other: return true
            }
        }
        guard let idx = text.unicodeScalars.firstIndex(where: belongs) else { return "" }
        return String(text.unicodeScalars[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一段文字是否可能屬於這個語言（寬鬆版，用在逐段修剪）。
    static func segmentFits(_ text: String, _ language: Language) -> Bool {
        let s = dominantScript(text)
        if s == .other { return true }   // 只有標點、空白
        switch language.script {
        case .han: return s == .han
        case .kana: return s == .kana || s == .han   // 日文漢字
        case .hangul: return s == .hangul
        case .latin: return s == .latin
        case .other: return true
        }
    }

    /// 這段文字整體是否像這個語言：看該語言的文字系統佔字母的比例，不是只看有沒有出現。
    /// （日文通道聽英文會吐出「ビュー the Cordely Reselt」這種：有假名，但拉丁字母佔多數。）
    static func scriptMatches(_ text: String, _ language: Language) -> Bool {
        var han = 0, kana = 0, hangul = 0, latin = 0, total = 0
        for u in text.unicodeScalars where CharacterSet.letters.contains(u) {
            total += 1
            switch u.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x0041...0x024F: latin += 1
            default: break
            }
        }
        guard total > 0 else { return true }
        let t = Double(total)
        switch language.script {
        case .han: return han > 0 && kana == 0 && hangul == 0 && Double(han) / t >= 0.6
        case .kana: return kana > 0 && Double(kana + han) / t >= 0.6
        case .hangul: return Double(hangul) / t >= 0.6
        case .latin: return Double(latin) / t >= 0.6
        case .other: return true
        }
    }
}
