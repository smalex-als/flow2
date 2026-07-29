import Foundation

enum TranslationLanguage: String, Codable, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"
    case ukrainian = "uk"
    case spanish = "es"
    case portuguese = "pt"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case dutch = "nl"
    case polish = "pl"
    case turkish = "tr"
    case arabic = "ar"
    case hebrew = "he"
    case hindi = "hi"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var shortCode: String { rawValue.uppercased() }

    /// Also the name given to the model, so it stays in English rather than following the locale.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Russian"
        case .ukrainian: return "Ukrainian"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .dutch: return "Dutch"
        case .polish: return "Polish"
        case .turkish: return "Turkish"
        case .arabic: return "Arabic"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .chinese: return "Simplified Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        }
    }
}

enum TranslationModelPreset: String, Codable, CaseIterable, Identifiable {
    case gpt56Luna = "gpt-5.6-luna"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt56Sol = "gpt-5.6-sol"
    case gpt54Nano = "gpt-5.4-nano"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt54 = "gpt-5.4"

    var id: String { rawValue }

    static var allCases: [TranslationModelPreset] {
        [.gpt56Luna, .gpt56Terra, .gpt56Sol]
    }

    var displayName: String {
        switch self {
        case .gpt56Luna:
            return "GPT-5.6 Luna"
        case .gpt56Terra:
            return "GPT-5.6 Terra"
        case .gpt56Sol:
            return "GPT-5.6 Sol"
        case .gpt54Nano:
            return "GPT-5.4 Nano (Legacy)"
        case .gpt54Mini:
            return "GPT-5.4 Mini (Legacy)"
        case .gpt54:
            return "GPT-5.4 (Legacy)"
        }
    }

    var currentEquivalent: TranslationModelPreset {
        switch self {
        case .gpt54Nano:
            return .gpt56Luna
        case .gpt54Mini:
            return .gpt56Terra
        case .gpt54:
            return .gpt56Sol
        case .gpt56Luna, .gpt56Terra, .gpt56Sol:
            return self
        }
    }
}

struct AppConfiguration: Codable, Equatable {
    private struct LegacyPronunciationDictionaryEntry: Decodable {
        let preferred: String?
    }

    private enum LegacyHotKeyPreset: String, Decodable {
        case controlSpace
        case shiftCommandSpace
        case optionCommandSpace

        var shortcut: HotKeyShortcut {
            switch self {
            case .controlSpace:
                return .controlSpace
            case .shiftCommandSpace:
                return .shiftCommandSpace
            case .optionCommandSpace:
                return .optionCommandSpace
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case configVersion
        case apiKey
        case translationModel
        case translationSourceLanguage
        case translationTargetLanguage
        case preferredTerms
        case translateHotKey
        case dictateHotKey
        case launchAtLogin

        // Read-only, for configurations written before dictation became two modes.
        case editingModel
        case autoTranslateRussianToEnglish
        case pronunciationDictionary
        case hotKey
        case hotKeyPreset
        case noTranslateHotKey
        case noTranslateHotKeyPreset
    }

    static let currentConfigVersion = 8
    static let defaultTranslationModel: TranslationModelPreset = .gpt56Luna
    static let defaultTranslateHotKey: HotKeyShortcut = .controlSpace
    static let defaultDictateHotKey: HotKeyShortcut = .shiftCommandSpace

    var configVersion = Self.currentConfigVersion
    var apiKey = ""
    var translationModel = Self.defaultTranslationModel
    /// `nil` means any language: the model detects it and leaves text already in the target alone.
    var translationSourceLanguage: TranslationLanguage?
    var translationTargetLanguage: TranslationLanguage = .english
    var preferredTerms: [String] = []
    var translateHotKey: HotKeyShortcut = Self.defaultTranslateHotKey
    var dictateHotKey: HotKeyShortcut = Self.defaultDictateHotKey
    var launchAtLogin = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedConfigVersion = try container.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
        configVersion = Self.currentConfigVersion
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false

        let decodedModel = try container.decodeIfPresent(TranslationModelPreset.self, forKey: .translationModel)
            ?? container.decodeIfPresent(TranslationModelPreset.self, forKey: .editingModel)
            ?? Self.defaultTranslationModel
        translationModel = decodedConfigVersion < 3 ? decodedModel.currentEquivalent : decodedModel

        translationTargetLanguage = try container.decodeIfPresent(TranslationLanguage.self, forKey: .translationTargetLanguage) ?? .english
        if let decodedSource = try container.decodeIfPresent(TranslationLanguage.self, forKey: .translationSourceLanguage) {
            translationSourceLanguage = decodedSource
        } else if Self.isPreLanguageDocument(container, version: decodedConfigVersion) {
            // Translation used to be Russian-only, so a configuration written back then keeps doing
            // exactly what it did. A fresh install starts on "any language" instead.
            translationSourceLanguage = .russian
        }

        if let decodedPreferredTerms = try container.decodeIfPresent([String].self, forKey: .preferredTerms) {
            preferredTerms = Self.normalizedPreferredTerms(decodedPreferredTerms)
        } else {
            let legacyEntries = try container.decodeIfPresent([LegacyPronunciationDictionaryEntry].self, forKey: .pronunciationDictionary) ?? []
            preferredTerms = Self.normalizedPreferredTerms(legacyEntries.compactMap(\.preferred))
        }

        let decodedTranslateHotKey = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .translateHotKey)
        let decodedDictateHotKey = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .dictateHotKey)
        let legacyMainHotKey = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .hotKey)
            ?? container.decodeIfPresent(LegacyHotKeyPreset.self, forKey: .hotKeyPreset)?.shortcut

        if decodedTranslateHotKey != nil || decodedDictateHotKey != nil {
            translateHotKey = decodedTranslateHotKey ?? Self.defaultTranslateHotKey
            dictateHotKey = decodedDictateHotKey ?? Self.defaultDictateHotKey
        } else if let legacyMainHotKey {
            // Before version 7 there was one main shortcut plus an optional second one that skipped
            // translation. Which mode the main one meant depended on the translation setting, so it
            // decides which of the two new shortcuts inherits it and keeps the user's muscle memory.
            let legacySecondaryHotKey = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .noTranslateHotKey)
                ?? container.decodeIfPresent(LegacyHotKeyPreset.self, forKey: .noTranslateHotKeyPreset)?.shortcut
                ?? Self.defaultDictateHotKey
            let legacyTranslated = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateRussianToEnglish) ?? false

            translateHotKey = legacyTranslated ? legacyMainHotKey : legacySecondaryHotKey
            dictateHotKey = legacyTranslated ? legacySecondaryHotKey : legacyMainHotKey
        }

        if dictateHotKey == translateHotKey {
            dictateHotKey = Self.fallbackShortcut(avoiding: translateHotKey)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configVersion, forKey: .configVersion)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(translationModel, forKey: .translationModel)
        try container.encodeIfPresent(translationSourceLanguage, forKey: .translationSourceLanguage)
        try container.encode(translationTargetLanguage, forKey: .translationTargetLanguage)
        try container.encode(preferredTerms, forKey: .preferredTerms)
        try container.encode(translateHotKey, forKey: .translateHotKey)
        try container.encode(dictateHotKey, forKey: .dictateHotKey)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
    }

    func hotKey(for mode: DictationMode) -> HotKeyShortcut {
        switch mode {
        case .dictate:
            return dictateHotKey
        case .translate:
            return translateHotKey
        }
    }

    /// Distinguishes a real configuration written before languages were selectable from an empty
    /// document, so decoding `{}` lands on the same defaults as a first launch with no file at all.
    private static func isPreLanguageDocument(_ container: KeyedDecodingContainer<CodingKeys>, version: Int) -> Bool {
        guard version < 8 else { return false }

        return container.contains(.configVersion)
            || container.contains(.hotKey)
            || container.contains(.hotKeyPreset)
            || container.contains(.editingModel)
            || container.contains(.pronunciationDictionary)
    }

    static func fallbackShortcut(avoiding shortcut: HotKeyShortcut) -> HotKeyShortcut {
        [.shiftCommandSpace, .optionCommandSpace, .controlOptionSpace, .controlSpace]
            .first { $0 != shortcut } ?? shortcut
    }

    private static func normalizedPreferredTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()

        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

final class ConfigurationStore {
    private let fileURL = AppStoragePaths.baseDirectory.appendingPathComponent("config.json")

    func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AppConfiguration()
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AppConfiguration.self, from: data)
    }

    func save(_ configuration: AppConfiguration) throws {
        let data = try JSONEncoder.pretty.encode(configuration)
        try data.write(to: fileURL, options: .atomic)
    }
}

enum AppStoragePaths {
    static let baseDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flow2", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
