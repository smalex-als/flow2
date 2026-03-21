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

struct AppConfiguration: Codable {
    static let defaultModel = "gpt-4o-mini-transcribe"
    static let defaultEditingModel = "gpt-5.4-nano"

    var apiKey = ""
    var model = Self.defaultModel
    var enableAIEditing = false
    var autoTranslateRussianToEnglish = false
    var hotKeyPreset: HotKeyPreset = .controlSpace
    var launchAtLogin = false
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
