import Foundation

enum HotKeyPreset: String, Codable, CaseIterable, Identifiable {
    case controlSpace
    case shiftCommandSpace
    case optionCommandSpace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .controlSpace:
            return "Control+Space"
        case .shiftCommandSpace:
            return "Shift+Command+Space"
        case .optionCommandSpace:
            return "Option+Command+Space"
        }
    }
}

enum EditingModelPreset: String, Codable, CaseIterable, Identifiable {
    case gpt56Luna = "gpt-5.6-luna"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt56Sol = "gpt-5.6-sol"
    case gpt54Nano = "gpt-5.4-nano"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt54 = "gpt-5.4"

    var id: String { rawValue }

    static var allCases: [EditingModelPreset] {
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

    var currentEquivalent: EditingModelPreset {
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

enum TranscriptionProvider: String, Codable, CaseIterable, Identifiable {
    case openAI
    case localWhisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI API"
        case .localWhisper:
            return "Local Whisper CLI"
        }
    }
}

struct AppConfiguration: Codable {
    private struct LegacyPronunciationDictionaryEntry: Decodable {
        let preferred: String?
    }

    private enum CodingKeys: String, CodingKey {
        case configVersion
        case apiKey
        case model
        case transcriptionProvider
        case localWhisperExecutablePath
        case localWhisperModel
        case editingModel
        case enableAIEditing
        case autoTranslateRussianToEnglish
        case preferredTerms
        case pronunciationDictionary
        case hotKeyPreset
        case enableNoTranslateHotKey
        case noTranslateHotKeyPreset
        case launchAtLogin
    }

    static let currentConfigVersion = 3
    static let defaultModel = "gpt-4o-mini-transcribe"
    static let defaultLocalWhisperExecutablePath = "/opt/homebrew/bin/whisper"
    static let defaultLocalWhisperModel = "base"
    static let defaultEditingModel: EditingModelPreset = .gpt56Luna
    static let defaultNoTranslateHotKeyPreset: HotKeyPreset = .shiftCommandSpace

    var configVersion = Self.currentConfigVersion
    var apiKey = ""
    var model = Self.defaultModel
    var transcriptionProvider: TranscriptionProvider = .openAI
    var localWhisperExecutablePath = Self.defaultLocalWhisperExecutablePath
    var localWhisperModel = Self.defaultLocalWhisperModel
    var editingModel = Self.defaultEditingModel
    var enableAIEditing = false
    var autoTranslateRussianToEnglish = false
    var preferredTerms: [String] = []
    var hotKeyPreset: HotKeyPreset = .controlSpace
    var enableNoTranslateHotKey = false
    var noTranslateHotKeyPreset: HotKeyPreset = Self.defaultNoTranslateHotKeyPreset
    var launchAtLogin = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedConfigVersion = try container.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
        configVersion = Self.currentConfigVersion
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""

        let decodedModel = try container.decodeIfPresent(String.self, forKey: .model)?.trimmingCharacters(in: .whitespacesAndNewlines)
        model = (decodedModel?.isEmpty == false) ? decodedModel! : Self.defaultModel

        transcriptionProvider = try container.decodeIfPresent(TranscriptionProvider.self, forKey: .transcriptionProvider) ?? .openAI

        let decodedWhisperPath = try container.decodeIfPresent(String.self, forKey: .localWhisperExecutablePath)?.trimmingCharacters(in: .whitespacesAndNewlines)
        localWhisperExecutablePath = (decodedWhisperPath?.isEmpty == false) ? decodedWhisperPath! : Self.defaultLocalWhisperExecutablePath

        let decodedWhisperModel = try container.decodeIfPresent(String.self, forKey: .localWhisperModel)?.trimmingCharacters(in: .whitespacesAndNewlines)
        localWhisperModel = (decodedWhisperModel?.isEmpty == false) ? decodedWhisperModel! : Self.defaultLocalWhisperModel

        let decodedEditingModel = try container.decodeIfPresent(EditingModelPreset.self, forKey: .editingModel) ?? Self.defaultEditingModel
        editingModel = decodedConfigVersion < 3 ? decodedEditingModel.currentEquivalent : decodedEditingModel
        enableAIEditing = try container.decodeIfPresent(Bool.self, forKey: .enableAIEditing) ?? false
        autoTranslateRussianToEnglish = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateRussianToEnglish) ?? false
        hotKeyPreset = try container.decodeIfPresent(HotKeyPreset.self, forKey: .hotKeyPreset) ?? .controlSpace
        enableNoTranslateHotKey = try container.decodeIfPresent(Bool.self, forKey: .enableNoTranslateHotKey) ?? false

        let decodedNoTranslatePreset = try container.decodeIfPresent(HotKeyPreset.self, forKey: .noTranslateHotKeyPreset)
            ?? Self.defaultNoTranslateHotKeyPreset
        noTranslateHotKeyPreset = decodedNoTranslatePreset == hotKeyPreset
            ? Self.fallbackNoTranslateHotKeyPreset(avoiding: hotKeyPreset)
            : decodedNoTranslatePreset

        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false

        if let decodedPreferredTerms = try container.decodeIfPresent([String].self, forKey: .preferredTerms) {
            preferredTerms = Self.normalizedPreferredTerms(decodedPreferredTerms)
        } else {
            let legacyEntries = try container.decodeIfPresent([LegacyPronunciationDictionaryEntry].self, forKey: .pronunciationDictionary) ?? []
            preferredTerms = Self.normalizedPreferredTerms(legacyEntries.compactMap(\.preferred))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configVersion, forKey: .configVersion)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(model, forKey: .model)
        try container.encode(transcriptionProvider, forKey: .transcriptionProvider)
        try container.encode(localWhisperExecutablePath, forKey: .localWhisperExecutablePath)
        try container.encode(localWhisperModel, forKey: .localWhisperModel)
        try container.encode(editingModel, forKey: .editingModel)
        try container.encode(enableAIEditing, forKey: .enableAIEditing)
        try container.encode(autoTranslateRussianToEnglish, forKey: .autoTranslateRussianToEnglish)
        try container.encode(preferredTerms, forKey: .preferredTerms)
        try container.encode(hotKeyPreset, forKey: .hotKeyPreset)
        try container.encode(enableNoTranslateHotKey, forKey: .enableNoTranslateHotKey)
        try container.encode(noTranslateHotKeyPreset, forKey: .noTranslateHotKeyPreset)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
    }

    static func fallbackNoTranslateHotKeyPreset(avoiding preset: HotKeyPreset) -> HotKeyPreset {
        HotKeyPreset.allCases.first { $0 != preset } ?? preset
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
