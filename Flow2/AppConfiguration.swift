import Foundation

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
        case editingModel
        case enableAIEditing
        case autoTranslateRussianToEnglish
        case preferredTerms
        case pronunciationDictionary
        case hotKey
        case hotKeyPreset
        case enableNoTranslateHotKey
        case noTranslateHotKey
        case noTranslateHotKeyPreset
        case launchAtLogin
    }

    static let currentConfigVersion = 6
    static let defaultEditingModel: EditingModelPreset = .gpt56Luna
    static let defaultNoTranslateHotKey: HotKeyShortcut = .shiftCommandSpace

    var configVersion = Self.currentConfigVersion
    var apiKey = ""
    var editingModel = Self.defaultEditingModel
    var enableAIEditing = false
    var autoTranslateRussianToEnglish = false
    var preferredTerms: [String] = []
    var hotKey: HotKeyShortcut = .controlSpace
    var enableNoTranslateHotKey = false
    var noTranslateHotKey: HotKeyShortcut = Self.defaultNoTranslateHotKey
    var launchAtLogin = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedConfigVersion = try container.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
        configVersion = Self.currentConfigVersion
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""

        let decodedEditingModel = try container.decodeIfPresent(EditingModelPreset.self, forKey: .editingModel) ?? Self.defaultEditingModel
        editingModel = decodedConfigVersion < 3 ? decodedEditingModel.currentEquivalent : decodedEditingModel
        enableAIEditing = try container.decodeIfPresent(Bool.self, forKey: .enableAIEditing) ?? false
        autoTranslateRussianToEnglish = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateRussianToEnglish) ?? false
        hotKey = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .hotKey)
            ?? container.decodeIfPresent(LegacyHotKeyPreset.self, forKey: .hotKeyPreset)?.shortcut
            ?? .controlSpace
        enableNoTranslateHotKey = try container.decodeIfPresent(Bool.self, forKey: .enableNoTranslateHotKey) ?? false

        let decodedNoTranslateHotKey = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .noTranslateHotKey)
            ?? container.decodeIfPresent(LegacyHotKeyPreset.self, forKey: .noTranslateHotKeyPreset)?.shortcut
            ?? Self.defaultNoTranslateHotKey
        noTranslateHotKey = decodedNoTranslateHotKey == hotKey
            ? Self.fallbackNoTranslateHotKey(avoiding: hotKey)
            : decodedNoTranslateHotKey

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
        try container.encode(editingModel, forKey: .editingModel)
        try container.encode(enableAIEditing, forKey: .enableAIEditing)
        try container.encode(autoTranslateRussianToEnglish, forKey: .autoTranslateRussianToEnglish)
        try container.encode(preferredTerms, forKey: .preferredTerms)
        try container.encode(hotKey, forKey: .hotKey)
        try container.encode(enableNoTranslateHotKey, forKey: .enableNoTranslateHotKey)
        try container.encode(noTranslateHotKey, forKey: .noTranslateHotKey)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
    }

    static func fallbackNoTranslateHotKey(avoiding hotKey: HotKeyShortcut) -> HotKeyShortcut {
        [.shiftCommandSpace, .optionCommandSpace, .controlOptionSpace]
            .first { $0 != hotKey } ?? hotKey
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
