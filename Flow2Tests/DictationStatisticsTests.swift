import XCTest

@testable import Flow2

/// The numbers are meant to be right in magnitude, so the tests pin the things that would be wrong
/// by a factor rather than by a rounding: the denominator of the daily rate, which recordings count
/// towards speed, and what a word is in a language that does not use spaces.
final class DictationStatisticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(daysAgo: Double = 0, seconds: TimeInterval = 60, words: Int, mode: DictationMode = .dictate) -> DictationRecord {
        DictationRecord(at: now.addingTimeInterval(-daysAgo * 86_400), seconds: seconds, words: words, mode: mode)
    }

    private func statistics(_ records: [DictationRecord]) -> DictationStatistics {
        DictationStatistics(records: records, now: now)
    }

    // MARK: - Totals

    func testNoRecordsReadAsZeroRatherThanDividingByZero() {
        XCTAssertEqual(statistics([]), .empty)
    }

    func testWordsAndDictationsAreCountedAcrossEverything() {
        let result = statistics([record(words: 100), record(daysAgo: 400, words: 50)])

        XCTAssertEqual(result.totalWords, 150, "the lifetime total ignores the recent window")
        XCTAssertEqual(result.dictations, 2)
    }

    // MARK: - Words per day

    /// The trap: dividing a couple of days of use by a 30-day window reports a rate an order of
    /// magnitude below the real one.
    func testTheDailyRateOnlyDividesByDaysThatCouldHaveContributed() {
        let result = statistics([record(daysAgo: 1, words: 600), record(words: 600)])

        XCTAssertEqual(result.wordsPerDay, 600, "two days of 600 words is 600 a day, not 40")
    }

    func testTheDailyRateDividesByTheFullWindowOnceItIsFilled() {
        let result = statistics((0 ..< 30).map { record(daysAgo: Double($0), words: 100) })

        XCTAssertEqual(result.wordsPerDay, 100)
    }

    /// A long-time user who dictated 100 words this week averages a few words a day, not fifty: the
    /// idle days are part of the window. Only somebody who started days ago gets a shorter one.
    func testWordsOlderThanTheWindowDoNotRaiseTheDailyRate() {
        let result = statistics([record(daysAgo: 200, words: 100_000), record(daysAgo: 1, words: 50), record(words: 50)])

        XCTAssertEqual(result.wordsPerDay, 3, "an old burst must not be spread over recent days")
        XCTAssertEqual(result.totalWords, 100_100, "but it still belongs to the lifetime total")
    }

    // MARK: - Speaking rate

    func testTheRateIsWordsOverMinutesSpoken() {
        let result = statistics([record(seconds: 60, words: 120), record(seconds: 60, words: 180)])

        XCTAssertEqual(result.wordsPerMinute, 150)
    }

    /// A two-word reply is mostly the silence around it, and averaging its apparent rate in would
    /// drag the figure well below how fast the user actually speaks.
    func testVeryShortRecordingsAreLeftOutOfTheRate() {
        let result = statistics([record(seconds: 60, words: 150), record(seconds: 1, words: 2)])

        XCTAssertEqual(result.wordsPerMinute, 150)
    }

    func testShortRecordingsStillCountTowardsTheWordTotal() {
        let result = statistics([record(seconds: 1, words: 2)])

        XCTAssertEqual(result.totalWords, 2)
        XCTAssertEqual(result.wordsPerMinute, 0, "with nothing long enough to measure, there is no rate to report")
    }

    func testALongRecordingWeighsMoreThanAShortOne() {
        let result = statistics([record(seconds: 600, words: 1_000), record(seconds: 6, words: 30)])

        XCTAssertEqual(result.wordsPerMinute, 102, "totals over totals, not an average of two rates")
    }

    // MARK: - Word counting

    func testWordsAreCountedAcrossPunctuationAndWhitespace() {
        XCTAssertEqual(WordCount.of("Hello, world - this is Flow2."), 5, "a lone dash is not a word")
        XCTAssertEqual(WordCount.of("  spaced   out \n lines "), 3)
    }

    func testEmptyTextHasNoWords() {
        XCTAssertEqual(WordCount.of(""), 0)
        XCTAssertEqual(WordCount.of("   \n  "), 0)
    }

    /// Word enumeration hands back the spaces in Cyrillic text as substrings of their own, so a
    /// naive count reports nearly double. Russian is the language this app is mostly used in.
    func testCyrillicCountsTheSameWayAsLatin() {
        XCTAssertEqual(WordCount.of("Привет, как дела?"), 3)
        XCTAssertEqual(WordCount.of("Привет"), 1)
    }

    /// Splitting on whitespace would call this one word.
    func testAScriptWithoutSpacesIsNotCountedAsOneWord() {
        XCTAssertGreaterThan(WordCount.of("今日はいい天気ですね"), 3)
    }

    // MARK: - Storage

    func testRecordsSurviveARoundTripThroughTheFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Flow2StatisticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DictationStatisticsStore(fileURL: directory.appendingPathComponent("stats.jsonl"))
        let first = record(seconds: 12.5, words: 40, mode: .translate)
        let second = record(seconds: 8, words: 20)

        try store.append(first)
        try store.append(second)

        XCTAssertEqual(try store.load(), [first, second], "appending must not overwrite what came before")
    }

    func testAReadingOfAFileThatDoesNotExistIsEmpty() throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Flow2StatisticsTests-\(UUID().uuidString).jsonl")

        XCTAssertEqual(try DictationStatisticsStore(fileURL: fileURL).load(), [])
    }

    /// A run killed mid-write leaves a partial last line. Everything before it is still good, and
    /// losing the whole history over one truncated tail would be the worse outcome.
    func testATruncatedLastLineDoesNotDiscardTheLinesBeforeIt() throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Flow2StatisticsTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = DictationStatisticsStore(fileURL: fileURL)
        try store.append(record(seconds: 10, words: 30))
        let good = try Data(contentsOf: fileURL)
        try (good + Data(#"{"at":"2026-08-0"#.utf8)).write(to: fileURL)

        XCTAssertEqual(try store.load().count, 1)
    }
}
