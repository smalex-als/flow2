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
    case gpt54Nano = "gpt-5.4-nano"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt54 = "gpt-5.4"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt54Nano:
            return "GPT-5.4 Nano"
        case .gpt54Mini:
            return "GPT-5.4 Mini"
        case .gpt54:
            return "GPT-5.4"
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
        case editingModel
        case enableAIEditing
        case autoTranslateRussianToEnglish
        case preferredTerms
        case pronunciationDictionary
        case hotKeyPreset
        case launchAtLogin
    }

    static let currentConfigVersion = 2
    static let defaultModel = "gpt-4o-mini-transcribe"
    static let defaultEditingModel: EditingModelPreset = .gpt54Nano

    var configVersion = Self.currentConfigVersion
    var apiKey = ""
    var model = Self.defaultModel
    var editingModel = Self.defaultEditingModel
    var enableAIEditing = false
    var autoTranslateRussianToEnglish = false
    var preferredTerms: [String] = []
    var hotKeyPreset: HotKeyPreset = .controlSpace
    var launchAtLogin = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        configVersion = try container.decodeIfPresent(Int.self, forKey: .configVersion) ?? Self.currentConfigVersion
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""

        let decodedModel = try container.decodeIfPresent(String.self, forKey: .model)?.trimmingCharacters(in: .whitespacesAndNewlines)
        model = (decodedModel?.isEmpty == false) ? decodedModel! : Self.defaultModel

        editingModel = try container.decodeIfPresent(EditingModelPreset.self, forKey: .editingModel) ?? Self.defaultEditingModel
        enableAIEditing = try container.decodeIfPresent(Bool.self, forKey: .enableAIEditing) ?? false
        autoTranslateRussianToEnglish = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateRussianToEnglish) ?? false
        hotKeyPreset = try container.decodeIfPresent(HotKeyPreset.self, forKey: .hotKeyPreset) ?? .controlSpace
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
        try container.encode(editingModel, forKey: .editingModel)
        try container.encode(enableAIEditing, forKey: .enableAIEditing)
        try container.encode(autoTranslateRussianToEnglish, forKey: .autoTranslateRussianToEnglish)
        try container.encode(preferredTerms, forKey: .preferredTerms)
        try container.encode(hotKeyPreset, forKey: .hotKeyPreset)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
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
