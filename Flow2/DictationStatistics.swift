import Foundation

/// One finished dictation, reduced to numbers.
///
/// Deliberately holds no transcript text. That is what makes it safe to keep every record forever,
/// unlike `history.json`, and it is why this file never needs the protection the API key does.
struct DictationRecord: Codable, Equatable {
    let at: Date
    let seconds: TimeInterval
    let words: Int
    let mode: DictationMode
}

/// The three numbers the app shows, and nothing else.
///
/// All of them are rounded to whole units: the question they answer is "roughly how much am I
/// dictating, and roughly how fast", and a decimal place would imply an accuracy the measurement
/// does not have — the clock runs from the moment the shortcut goes down, not from the first word.
struct DictationStatistics: Equatable {
    /// A recording is only counted towards speed once it is long enough for the silence at each end
    /// — pressing before speaking, releasing after — to be a small part of it rather than most of it.
    static let minimumSecondsForRate: TimeInterval = 3

    /// Long enough to smooth out a quiet day, short enough to still describe current habits.
    static let recentDays = 30

    static let empty = DictationStatistics(totalWords: 0, wordsPerDay: 0, wordsPerMinute: 0, dictations: 0)

    let totalWords: Int
    let wordsPerDay: Int
    let wordsPerMinute: Int
    let dictations: Int

    init(totalWords: Int, wordsPerDay: Int, wordsPerMinute: Int, dictations: Int) {
        self.totalWords = totalWords
        self.wordsPerDay = wordsPerDay
        self.wordsPerMinute = wordsPerMinute
        self.dictations = dictations
    }

    init(records: [DictationRecord], now: Date = Date(), calendar: Calendar = .current) {
        totalWords = records.reduce(0) { $0 + $1.words }
        dictations = records.count

        let cutoff = calendar.date(byAdding: .day, value: -Self.recentDays, to: now) ?? now
        let recent = records.filter { $0.at > cutoff }

        // Dividing a week of use by 30 would report a rate five times lower than the real one, so
        // the window only counts the days that could have contributed to it.
        let elapsedDays = records.map(\.at).min().map { earliest in
            (calendar.dateComponents([.day], from: max(earliest, cutoff), to: now).day ?? 0) + 1
        } ?? 1
        let days = max(1, min(Self.recentDays, elapsedDays))
        let recentWords = recent.reduce(0) { $0 + $1.words }
        wordsPerDay = Int((Double(recentWords) / Double(days)).rounded())

        // Totals over totals rather than an average of per-recording rates: one two-word reply
        // would otherwise weigh as much as a two-minute paragraph.
        let timed = records.filter { $0.seconds >= Self.minimumSecondsForRate }
        let spokenSeconds = timed.reduce(0) { $0 + $1.seconds }
        let spokenWords = timed.reduce(0) { $0 + $1.words }
        wordsPerMinute = spokenSeconds > 0 ? Int((Double(spokenWords) / (spokenSeconds / 60)).rounded()) : 0
    }
}

enum WordCount {
    /// Counts words the way the reader's language defines them.
    ///
    /// Splitting on whitespace would report a Chinese or Japanese sentence as one or two words,
    /// which is not a rounding error but an order of magnitude. Foundation's word enumeration knows
    /// where the boundaries are in a script that does not use spaces.
    ///
    /// The enumeration is not consistent about separators, though: on Cyrillic it hands back the
    /// spaces between words as substrings of their own — "Привет, как дела?" arrives as five pieces,
    /// three of them words — while on Latin text it does not. Counting only what contains a letter
    /// or a digit is what keeps a Russian transcript from reading as twice its length.
    static func of(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: .byWords) { substring, _, _, _ in
            guard let substring, substring.rangeOfCharacter(from: .alphanumerics) != nil else { return }
            count += 1
        }
        return count
    }
}

/// Appends one line of JSON per dictation.
///
/// A line at a time, rather than one rewritten array: the file only ever grows, and rewriting all
/// of it after every dictation would cost more each time. It also means a run cut short mid-write
/// costs the last line and nothing before it, so a truncated tail is read past rather than fatal.
final class DictationStatisticsStore {
    private let fileURL: URL

    init(fileURL: URL = AppStoragePaths.baseDirectory.appendingPathComponent("stats.jsonl")) {
        self.fileURL = fileURL
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func load() throws -> [DictationRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let contents = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        let decoder = Self.decoder

        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(DictationRecord.self, from: Data($0.utf8)) }
    }

    func append(_ record: DictationRecord) throws {
        var line = try Self.encoder.encode(record)
        line.append(contentsOf: [UInt8(ascii: "\n")])

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try line.write(to: fileURL, options: .atomic)
            return
        }

        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
