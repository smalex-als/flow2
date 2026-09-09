import AppKit
import XCTest

@testable import Flow2

@MainActor
final class TranslationRecoveryTests: XCTestCase {
    private var directory: URL!
    private var store: TranscriptHistoryStore!
    private var preview: TranscriptPreviewController!
    private var viewModel: AppViewModel!
    private var inserted: [String] = []
    private var requests: [TranslationRequest] = []
    private var keys: [String] = []
    private var shouldFail = true

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TranscriptHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        preview = TranscriptPreviewController()
        inserted = []
        requests = []
        keys = []
        shouldFail = true
        viewModel = AppViewModel(historyStore: store, preview: preview, translate: { [unowned self] request, key in
            requests.append(request)
            keys.append(key)
            if shouldFail { throw OpenAITranslationError.timedOut }
            return "Translated text"
        }, performInsertion: { [unowned self] text, _ in
            inserted.append(text)
            return "Test insertion"
        })
        // Never load configuration or call the real keychain, network, or general pasteboard.
        viewModel.configuration.apiKey = "test-key"
    }

    override func tearDown() async throws {
        preview.hide()
        viewModel = nil
        preview = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func failTranslation(shouldInsertExternally: Bool = true) async {
        await viewModel.finishTranscript("Original text", mode: .translate, targetApp: nil,
                                         shouldInsertExternally: shouldInsertExternally)
    }

    func testFailureSavesOriginalAndNeverInsertsIt() async throws {
        await failTranslation()

        XCTAssertEqual(inserted, [])
        XCTAssertEqual(viewModel.transcript, "Original text")
        XCTAssertEqual(try store.load().map(\.text), ["Original text"])
        XCTAssertEqual(viewModel.workflowPhase, .idle)
        XCTAssertTrue(preview.model.isTranslationFailure)
        XCTAssertTrue(preview.isShowing)
        XCTAssertFalse(preview.hasKeyboardFocus)
    }

    func testRetryUsesOriginalRequestAndUpdatesItsOwnHistoryEntry() async throws {
        viewModel.configuration.translationSourceLanguage = .russian
        viewModel.configuration.translationTargetLanguage = .english
        await failTranslation()
        let originalID = try XCTUnwrap(viewModel.transcriptHistory.first?.id)
        viewModel.transcriptHistory.insert(TranscriptHistoryItem(text: "Another entry"), at: 0)
        viewModel.configuration.translationTargetLanguage = .french
        viewModel.configuration.apiKey = "replacement-key"
        shouldFail = false

        await viewModel.retryTranslation()
        await viewModel.retryTranslation() // A completed recovery cannot insert twice.

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.sourceLanguage, .russian)
        XCTAssertEqual(requests.last?.targetLanguage, .english)
        XCTAssertEqual(requests.last?.previousMessages, requests.first?.previousMessages)
        XCTAssertEqual(keys, ["test-key", "replacement-key"])
        XCTAssertEqual(inserted, ["Translated text"])
        XCTAssertEqual(try store.load().map(\.text), ["Another entry", "Translated text"])
        XCTAssertEqual(viewModel.transcriptHistory.last?.id, originalID)
        XCTAssertFalse(preview.isShowing)
        XCTAssertEqual(viewModel.workflowPhase, .idle)
    }

    func testRepeatedFailureKeepsOneOriginalAndRecoveryAvailable() async throws {
        await failTranslation()
        await viewModel.retryTranslation()
        await viewModel.retryTranslation()

        XCTAssertEqual(inserted, [])
        XCTAssertEqual(try store.load().map(\.text), ["Original text"])
        XCTAssertTrue(preview.isShowing)
        XCTAssertFalse(preview.model.isWorking)
        XCTAssertEqual(viewModel.workflowPhase, .idle)
    }

    func testCopyAndDismissPreserveOriginalWithoutInsertion() async throws {
        await failTranslation()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        viewModel.copyOriginalTranscript(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original text")
        XCTAssertTrue(preview.isShowing)

        viewModel.dismissTranslationFailure()
        shouldFail = false
        await viewModel.retryTranslation()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(inserted, [])
        XCTAssertFalse(preview.isShowing)
        XCTAssertEqual(try store.load().map(\.text), ["Original text"])
    }

    func testRetryForWindowOnlyTranscriptDoesNotInsertExternally() async {
        await failTranslation(shouldInsertExternally: false)
        shouldFail = false
        await viewModel.retryTranslation()

        XCTAssertEqual(viewModel.transcript, "Translated text")
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(viewModel.workflowPhase, .idle)
    }

    func testPlainDictationStillInsertsWithoutTranslation() async {
        await viewModel.finishTranscript("Original text", mode: .dictate, targetApp: nil,
                                         shouldInsertExternally: true)
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(inserted, ["Original text"])
    }

    func testSuccessfulTranslationStillInsertsImmediately() async {
        shouldFail = false
        await failTranslation()
        XCTAssertEqual(inserted, ["Translated text"])
        XCTAssertEqual(viewModel.transcriptHistory.map(\.text), ["Translated text"])
        XCTAssertFalse(preview.isShowing)
    }
}
