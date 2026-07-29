import AppKit
import XCTest

@testable import Flow2

/// Dictating into a paste-only app overwrites the clipboard and then puts it back. Getting the
/// restore wrong silently costs the user whatever they had copied, which is exactly the kind of
/// loss nobody reports as a bug — they just distrust the app.
///
/// Everything here runs on a private pasteboard: the tests must never touch what the person
/// running them has on their real clipboard.
final class PasteboardSnapshotTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.smalex.Flow2.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    /// Stands in for what the app does: snapshot, overwrite with the transcript, put the original back.
    private func roundTrip() {
        let snapshot = PasteboardSnapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("TRANSCRIPT", forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), "TRANSCRIPT", "the transcript should be on the pasteboard to paste")
        snapshot.write(to: pasteboard)
    }

    func testPlainTextComesBack() {
        pasteboard.clearContents()
        pasteboard.setString("привет 123", forType: .string)

        roundTrip()

        XCTAssertEqual(pasteboard.string(forType: .string), "привет 123")
    }

    func testEveryTypeOnAnItemComesBack() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("plain".utf8), forType: .string)
        item.setData(Data(#"{\rtf1 rich}"#.utf8), forType: .rtf)
        pasteboard.writeObjects([item])

        roundTrip()

        XCTAssertEqual(pasteboard.string(forType: .string), "plain")
        XCTAssertEqual(pasteboard.data(forType: .rtf).map { String(decoding: $0, as: UTF8.self) }, #"{\rtf1 rich}"#)
    }

    func testMultipleItemsComeBackInOrder() {
        pasteboard.clearContents()
        pasteboard.writeObjects(["one", "two", "three"].map { text in
            let item = NSPasteboardItem()
            item.setData(Data(text.utf8), forType: .string)
            return item
        })

        roundTrip()

        let restored = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }
        XCTAssertEqual(restored, ["one", "two", "three"])
    }

    func testURLComesBack() {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com/x?a=1")! as NSURL])

        roundTrip()

        XCTAssertEqual(NSURL(from: pasteboard)?.absoluteString, "https://example.com/x?a=1")
    }

    func testImageComesBack() {
        pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemPink.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        image.unlockFocus()
        pasteboard.writeObjects([image])

        roundTrip()

        XCTAssertEqual(NSImage(pasteboard: pasteboard)?.size, NSSize(width: 8, height: 8))
    }

    /// Nothing was there to begin with, so the transcript must not be left sitting on the clipboard.
    func testAnEmptyClipboardIsLeftEmpty() {
        pasteboard.clearContents()

        roundTrip()

        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testEmptinessIsReportedFromWhatWasCaptured() {
        pasteboard.clearContents()
        XCTAssertTrue(PasteboardSnapshot(of: pasteboard).isEmpty)

        pasteboard.setString("something", forType: .string)
        XCTAssertFalse(PasteboardSnapshot(of: pasteboard).isEmpty)
    }
}
