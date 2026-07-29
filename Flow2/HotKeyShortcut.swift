import Foundation

struct HotKeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8

    static let command = HotKeyModifiers(rawValue: 1 << 0)
    static let option = HotKeyModifiers(rawValue: 1 << 1)
    static let control = HotKeyModifiers(rawValue: 1 << 2)
    static let shift = HotKeyModifiers(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UInt8.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct HotKeyShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: HotKeyModifiers
    let keyDisplay: String

    static let controlSpace = HotKeyShortcut(
        keyCode: 49,
        modifiers: [.control],
        keyDisplay: "Space"
    )

    static let shiftCommandSpace = HotKeyShortcut(
        keyCode: 49,
        modifiers: [.shift, .command],
        keyDisplay: "Space"
    )

    static let optionCommandSpace = HotKeyShortcut(
        keyCode: 49,
        modifiers: [.option, .command],
        keyDisplay: "Space"
    )

    static let controlOptionSpace = HotKeyShortcut(
        keyCode: 49,
        modifiers: [.control, .option],
        keyDisplay: "Space"
    )

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }
        return result + keyDisplay
    }
}
