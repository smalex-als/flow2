import XCTest

@testable import Flow2

/// The meter's whole job is telling a live microphone from a dead one, so the decibel window it
/// maps has to keep room tone low and speech high. The bounds below come from measurement on a
/// real machine: an idle room reads about -38 dB and speech peaks near -7 dB.
final class AudioLevelTests: XCTestCase {
    func testSilenceReadsAsZero() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(decibels: -160), 0)
        XCTAssertEqual(AudioRecorder.normalizedLevel(decibels: -45), 0)
        XCTAssertEqual(AudioRecorder.normalizedLevel(decibels: -46), 0)
    }

    func testFullScaleReadsAsOne() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(decibels: 0), 1)
    }

    func testLevelIsClampedAboveFullScale() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(decibels: 12), 1)
    }

    func testRoomToneStaysASliverAndSpeechFillsMostOfTheBar() {
        let roomTone = AudioRecorder.normalizedLevel(decibels: -38)
        let speech = AudioRecorder.normalizedLevel(decibels: -7)

        XCTAssertLessThan(roomTone, 0.25, "an idle room should not look like a half-full meter")
        XCTAssertGreaterThan(speech, 0.75, "speech should be unmistakable")
    }

    func testLevelRisesWithLoudness() {
        let steps = [-44, -35, -25, -15, -5, 0].map { AudioRecorder.normalizedLevel(decibels: Float($0)) }

        XCTAssertEqual(steps, steps.sorted(), "a louder signal must never read quieter")
    }
}
