import XCTest

@testable import Flow2

/// Moving the key off disk is only worth anything if the plaintext copy actually goes away, and
/// only safe if a keychain that cannot be reached is never mistaken for an empty one. Both are
/// decided once, in `ConfigurationStore`, and then trusted for the life of the install.
///
/// The real keychain is never touched: the suite must not add, rewrite, or delete entries in the
/// login keychain of whoever runs it.
final class APIKeyStorageTests: XCTestCase {
    private final class SecretStoreDouble: SecretStore {
        var secret: String?
        var isReadable = true
        private(set) var deleteCount = 0

        init(secret: String? = nil) {
            self.secret = secret
        }

        struct Unavailable: Error {}

        func load() throws -> String? {
            guard isReadable else { throw Unavailable() }
            return secret
        }

        func save(_ secret: String) throws {
            guard isReadable else { throw Unavailable() }
            self.secret = secret
        }

        func delete() throws {
            guard isReadable else { throw Unavailable() }
            deleteCount += 1
            secret = nil
        }
    }

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Flow2ConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: fileURL)
    }

    private func fileContents() throws -> String {
        String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
    }

    private func makeStore(_ secretStore: SecretStore) -> ConfigurationStore {
        ConfigurationStore(fileURL: fileURL, secretStore: secretStore)
    }

    // MARK: - Migration

    func testAPlaintextKeyMovesToTheSecretStoreAndLeavesTheFile() throws {
        try write(#"{ "configVersion": 8, "apiKey": "sk-plaintext", "launchAtLogin": true }"#)
        let secretStore = SecretStoreDouble()

        let configuration = try makeStore(secretStore).load()

        XCTAssertEqual(configuration.apiKey, "sk-plaintext", "the key must survive the move")
        XCTAssertEqual(secretStore.secret, "sk-plaintext")
        XCTAssertFalse(try fileContents().contains("sk-plaintext"), "the plaintext copy is the whole problem")
        XCTAssertFalse(try fileContents().contains("apiKey"))
        XCTAssertTrue(configuration.launchAtLogin, "the rest of the configuration must come through untouched")
    }

    func testMigrationDoesNotStripTheFileWhenTheSecretStoreRefuses() throws {
        try write(#"{ "configVersion": 8, "apiKey": "sk-plaintext" }"#)
        let secretStore = SecretStoreDouble()
        secretStore.isReadable = false

        XCTAssertThrowsError(try makeStore(secretStore).load())
        XCTAssertTrue(try fileContents().contains("sk-plaintext"),
                      "the key would otherwise exist in neither place")
    }

    func testABlankPlaintextKeyIsNotMigrated() throws {
        try write(#"{ "configVersion": 8, "apiKey": "   " }"#)
        let secretStore = SecretStoreDouble()

        XCTAssertEqual(try makeStore(secretStore).load().apiKey, "")
        XCTAssertNil(secretStore.secret)
    }

    // MARK: - Reading

    func testTheKeyComesBackFromTheSecretStoreOnLaterLaunches() throws {
        try write(#"{ "configVersion": 9, "launchAtLogin": false }"#)

        XCTAssertEqual(try makeStore(SecretStoreDouble(secret: "sk-stored")).load().apiKey, "sk-stored")
    }

    func testTheKeyIsFoundEvenWithNoConfigurationFileYet() throws {
        XCTAssertEqual(try makeStore(SecretStoreDouble(secret: "sk-stored")).load().apiKey, "sk-stored")
    }

    func testAnUnreadableSecretStoreFailsTheLoadInsteadOfReportingNoKey() {
        let secretStore = SecretStoreDouble(secret: "sk-stored")
        secretStore.isReadable = false

        XCTAssertThrowsError(try makeStore(secretStore).load())
    }

    // MARK: - Writing

    func testSavingKeepsTheKeyOutOfTheFile() throws {
        var configuration = AppConfiguration()
        configuration.apiKey = "sk-new"
        let secretStore = SecretStoreDouble()

        try makeStore(secretStore).save(configuration)

        XCTAssertEqual(secretStore.secret, "sk-new")
        XCTAssertFalse(try fileContents().contains("sk-new"))
    }

    func testClearingTheKeyRemovesItFromTheSecretStore() throws {
        let secretStore = SecretStoreDouble(secret: "sk-old")

        try makeStore(secretStore).save(AppConfiguration())

        XCTAssertNil(secretStore.secret)
        XCTAssertEqual(secretStore.deleteCount, 1)
    }

    /// Settings save on every edit, so an unchanged key must not be rewritten — each write is a
    /// keychain operation that can prompt.
    func testAnUnchangedKeyIsNotRewritten() throws {
        var configuration = AppConfiguration()
        configuration.apiKey = "sk-same"
        let secretStore = SecretStoreDouble(secret: "sk-same")

        try makeStore(secretStore).save(configuration)

        XCTAssertEqual(secretStore.secret, "sk-same")
        XCTAssertEqual(secretStore.deleteCount, 0)
    }

    /// The dangerous case: a keychain that cannot be read looks exactly like one holding nothing,
    /// and treating the two the same would delete a good key on the next unrelated settings change.
    func testAnUnreadableSecretStoreNeverDeletesTheStoredKey() throws {
        try write(#"{ "configVersion": 9 }"#)
        let secretStore = SecretStoreDouble(secret: "sk-precious")
        secretStore.isReadable = false

        XCTAssertThrowsError(try makeStore(secretStore).save(AppConfiguration()))
        XCTAssertEqual(secretStore.deleteCount, 0)
        XCTAssertEqual(secretStore.secret, "sk-precious")
    }

    func testARoundTripThroughTheStoreKeepsTheKeyAndTheSettings() throws {
        var configuration = AppConfiguration()
        configuration.apiKey = "sk-round"
        configuration.translationTargetLanguage = .japanese
        configuration.preferredTerms = ["Flow2"]
        let secretStore = SecretStoreDouble()

        let store = makeStore(secretStore)
        try store.save(configuration)
        let restored = try store.load()

        XCTAssertEqual(restored, configuration)
        XCTAssertEqual(restored.apiKey, "sk-round")
    }
}
