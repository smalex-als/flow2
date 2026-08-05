import XCTest

@testable import Flow2

/// Chunking decides what actually reaches a terminal, and a mistake here is silent: the text is
/// posted, the app reports success, and the user finds mangled characters in their shell. The
/// invariants below are the ones the key event API imposes — a bounded length, and surrogate pairs
/// that stay together.
final class TerminalTypingChunkTests: XCTestCase {
    private func text(from chunks: [[UInt16]]) -> String {
        String(decoding: chunks.flatMap { $0 }, as: UTF16.self)
    }

    func testEmptyTextProducesNoEvents() {
        XCTAssertTrue(TextInsertionService.typingChunks(of: "").isEmpty)
    }

    func testShortTextFitsInOneEvent() {
        let chunks = TextInsertionService.typingChunks(of: "ls -la")

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(text(from: chunks), "ls -la")
    }

    func testNoChunkExceedsWhatOneEventCanCarry() {
        let chunks = TextInsertionService.typingChunks(of: String(repeating: "a", count: 205))

        XCTAssertEqual(chunks.count, 11)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, TextInsertionService.typingChunkLength)
            XCTAssertFalse(chunk.isEmpty, "an empty event would be posted for nothing")
        }
    }

    func testTranscriptSurvivesChunking() {
        let transcript = "git commit -m \"Обновить README, добавить 🙂 и 漢字\" && git push"

        XCTAssertEqual(text(from: TextInsertionService.typingChunks(of: transcript)), transcript)
    }

    /// The emoji straddles the chunk boundary: 19 leading characters put its high surrogate at the
    /// last slot of the first event and its low surrogate at the first slot of the next.
    func testASurrogatePairIsNeverSplitAcrossEvents() {
        let chunks = TextInsertionService.typingChunks(of: String(repeating: "a", count: 19) + "🙂tail")

        XCTAssertEqual(chunks[0].count, 19, "the pair must move to the next event rather than be cut")
        XCTAssertEqual(text(from: chunks), String(repeating: "a", count: 19) + "🙂tail")
        for chunk in chunks {
            XCTAssertFalse((0xD800 ... 0xDBFF).contains(chunk[chunk.count - 1]),
                           "an event must not end on a high surrogate")
        }
    }

    /// A non-BMP scalar used to be forced into a `UniChar` one scalar at a time, which trapped and
    /// took the app down mid-insertion.
    func testTextThatIsEntirelyNonBMPIsCarried() {
        let emoji = String(repeating: "🙂", count: 30)

        XCTAssertEqual(text(from: TextInsertionService.typingChunks(of: emoji)), emoji)
    }
}
