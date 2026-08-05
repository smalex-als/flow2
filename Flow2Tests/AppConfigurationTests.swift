import XCTest

@testable import Flow2

/// `AppConfiguration.init(from:)` reads every layout the app has ever written, from version 1 to 8,
/// and a silent regression there rewrites somebody's shortcuts or translation languages without
/// anything looking broken. These pin the decisions down.
final class AppConfigurationTests: XCTestCase {
    private func decode(_ json: String) throws -> AppConfiguration {
        try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
    }

    // MARK: - Hot key migration

    func testTranslatingMainShortcutBecomesTheTranslateMode() throws {
        let configuration = try decode("""
        {
          "configVersion": 6,
          "autoTranslateRussianToEnglish": true,
          "enableNoTranslateHotKey": true,
          "hotKey": { "keyCode": 49, "keyDisplay": "Space", "modifiers": 4 },
          "noTranslateHotKey": { "keyCode": 49, "keyDisplay": "Space", "modifiers": 9 }
        }
        """)

        XCTAssertEqual(configuration.translateHotKey, .controlSpace)
        XCTAssertEqual(configuration.dictateHotKey, .shiftCommandSpace)
    }

    func testNonTranslatingMainShortcutBecomesThePlainMode() throws {
        let configuration = try decode("""
        {
          "configVersion": 6,
          "autoTranslateRussianToEnglish": false,
          "hotKey": { "keyCode": 49, "keyDisplay": "Space", "modifiers": 4 },
          "noTranslateHotKey": { "keyCode": 49, "keyDisplay": "Space", "modifiers": 9 }
        }
        """)

        XCTAssertEqual(configuration.dictateHotKey, .controlSpace)
        XCTAssertEqual(configuration.translateHotKey, .shiftCommandSpace)
    }

    /// The second shortcut used to be opt-in. Both modes exist unconditionally now, so a disabled
    /// one still has to come back reachable rather than leaving a mode with no way to trigger it.
    func testDisabledSecondShortcutStillYieldsTwoReachableModes() throws {
        let configuration = try decode("""
        {
          "configVersion": 6,
          "autoTranslateRussianToEnglish": true,
          "enableNoTranslateHotKey": false,
          "hotKey": { "keyCode": 49, "keyDisplay": "Space", "modifiers": 4 },
          "noTranslateHotKey": { "keyCode": 49, "keyDisplay": "Space", "modifiers": 9 }
        }
        """)

        XCTAssertEqual(configuration.translateHotKey, .controlSpace)
        XCTAssertEqual(configuration.dictateHotKey, .shiftCommandSpace)
        XCTAssertNotEqual(configuration.dictateHotKey, configuration.translateHotKey)
    }

    func testCollidingShortcutsAreSeparated() throws {
        let configuration = try decode("""
        {
          "configVersion": 6,
          "autoTranslateRussianToEnglish": true,
          "hotKey": { "keyCode": 49, "keyDisplay": "Space", "modifiers": 4 },
          "noTranslateHotKey": { "keyCode": 49, "keyDisplay": "Space", "modifiers": 4 }
        }
        """)

        XCTAssertEqual(configuration.translateHotKey, .controlSpace)
        XCTAssertNotEqual(configuration.dictateHotKey, configuration.translateHotKey)
    }

    func testLegacyPresetAndPronunciationDictionaryAreMigrated() throws {
        let configuration = try decode("""
        {
          "apiKey": "k",
          "editingModel": "gpt-5.4-mini",
          "hotKeyPreset": "optionCommandSpace",
          "pronunciationDictionary": [
            { "preferred": "Flow2" },
            { "preferred": "flow2" },
            { "preferred": "   " }
          ]
        }
        """)

        XCTAssertEqual(configuration.dictateHotKey, .optionCommandSpace)
        XCTAssertNotEqual(configuration.translateHotKey, configuration.dictateHotKey)
        XCTAssertEqual(configuration.translationModel, .gpt56Terra, "a legacy model should map to its current equivalent")
        XCTAssertEqual(configuration.preferredTerms, ["Flow2"], "terms differing only in case are one term")
    }

    // MARK: - Languages

    func testConfigurationsPredatingLanguagesStayRussianToEnglish() throws {
        let configuration = try decode(#"{ "configVersion": 7, "translationModel": "gpt-5.6-terra" }"#)

        XCTAssertEqual(configuration.translationSourceLanguage, .russian)
        XCTAssertEqual(configuration.translationTargetLanguage, .english)
    }

    func testStoredLanguagesAreKept() throws {
        let configuration = try decode("""
        {
          "configVersion": 8,
          "translationSourceLanguage": "es",
          "translationTargetLanguage": "de"
        }
        """)

        XCTAssertEqual(configuration.translationSourceLanguage, .spanish)
        XCTAssertEqual(configuration.translationTargetLanguage, .german)
    }

    func testAbsentSourceLanguageMeansAnyLanguage() throws {
        let configuration = try decode(#"{ "configVersion": 8, "translationTargetLanguage": "ja" }"#)

        XCTAssertNil(configuration.translationSourceLanguage)
        XCTAssertEqual(configuration.translationTargetLanguage, .japanese)
    }

    /// An empty document is not an old configuration, and treating it as one used to flip both the
    /// shortcuts and the source language relative to a genuine first launch.
    func testEmptyDocumentDecodesToFirstLaunchDefaults() throws {
        let decoded = try decode("{}")
        let fresh = AppConfiguration()

        XCTAssertEqual(decoded.translateHotKey, fresh.translateHotKey)
        XCTAssertEqual(decoded.dictateHotKey, fresh.dictateHotKey)
        XCTAssertEqual(decoded.translationSourceLanguage, fresh.translationSourceLanguage)
        XCTAssertEqual(decoded.translationTargetLanguage, fresh.translationTargetLanguage)
    }

    func testFirstLaunchStartsOnAnyLanguage() {
        XCTAssertNil(AppConfiguration().translationSourceLanguage)
        XCTAssertEqual(AppConfiguration().translationTargetLanguage, .english)
    }

    // MARK: - Round trip

    func testEncodingThenDecodingPreservesEverything() throws {
        var original = AppConfiguration()
        original.translationModel = .gpt56Sol
        original.translationSourceLanguage = .korean
        original.translationTargetLanguage = .hindi
        original.preferredTerms = ["Flow2", "iTerm2"]
        original.translateHotKey = .optionCommandSpace
        original.dictateHotKey = .controlOptionSpace
        original.launchAtLogin = true

        let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(restored, original)
    }

    func testAnyLanguageSurvivesARoundTrip() throws {
        var original = AppConfiguration()
        original.translationSourceLanguage = nil

        let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(original))

        XCTAssertNil(restored.translationSourceLanguage)
    }

    /// The key belongs to the keychain now, and an encoder that still emits it would quietly put a
    /// plaintext copy back on disk every time a setting changed.
    func testTheAPIKeyIsNeverEncoded() throws {
        var configuration = AppConfiguration()
        configuration.apiKey = "sk-secret"

        let encoded = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)

        XCTAssertFalse(encoded.contains("sk-secret"))
        XCTAssertFalse(encoded.contains("apiKey"))
    }

    func testAStoredPlaintextKeyIsNotDecodedBackIntoTheConfiguration() throws {
        XCTAssertEqual(try decode(#"{ "configVersion": 8, "apiKey": "sk-old" }"#).apiKey, "")
    }

    func testDecodingAlwaysReportsTheCurrentVersion() throws {
        XCTAssertEqual(try decode(#"{ "configVersion": 2 }"#).configVersion, AppConfiguration.currentConfigVersion)
    }

    // MARK: - Preferred terms

    func testPreferredTermsAreTrimmedDeduplicatedAndCompacted() throws {
        let configuration = try decode("""
        { "configVersion": 8, "preferredTerms": ["  Flow2  ", "", "FLOW2", "iTerm2", "   "] }
        """)

        XCTAssertEqual(configuration.preferredTerms, ["Flow2", "iTerm2"])
    }

    // MARK: - Shortcut helpers

    func testFallbackShortcutNeverReturnsTheOneBeingAvoided() {
        for shortcut in [HotKeyShortcut.controlSpace, .shiftCommandSpace, .optionCommandSpace, .controlOptionSpace] {
            XCTAssertNotEqual(AppConfiguration.fallbackShortcut(avoiding: shortcut), shortcut)
        }
    }

    func testShortcutLookupMatchesTheStoredPair() {
        var configuration = AppConfiguration()
        configuration.dictateHotKey = .optionCommandSpace
        configuration.translateHotKey = .controlOptionSpace

        XCTAssertEqual(configuration.hotKey(for: .dictate), .optionCommandSpace)
        XCTAssertEqual(configuration.hotKey(for: .translate), .controlOptionSpace)
    }

    func testDisplayNameOrdersModifiersConsistently() {
        XCTAssertEqual(HotKeyShortcut.controlSpace.displayName, "⌃Space")
        XCTAssertEqual(HotKeyShortcut.shiftCommandSpace.displayName, "⇧⌘Space")
        XCTAssertEqual(HotKeyShortcut.optionCommandSpace.displayName, "⌥⌘Space")
    }
}
