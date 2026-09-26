import XCTest
@testable import MacNotchIsland

/// What a backend reports is not always a number the island can do arithmetic with.
final class NowPlayingSanitizeTests: XCTestCase {
    private func info(duration: TimeInterval, elapsed: TimeInterval, timestamp: Date = Date()) -> NowPlayingInfo {
        NowPlayingInfo(title: "Live", artist: "Radio", album: "", duration: duration, elapsed: elapsed, timestamp: timestamp,
                       isPlaying: true, bundleID: nil, artwork: nil, artworkID: 0, accent: .white)
    }

    func testNonFiniteTimesBecomeZero() {
        let stream = NowPlayingService.sanitized(info(duration: .infinity, elapsed: .nan))
        XCTAssertEqual(stream.duration, 0)
        XCTAssertEqual(stream.elapsed, 0)
        XCTAssertEqual(stream.position(at: Date().addingTimeInterval(10)).mmss, "0:10", "a stream still counts up from zero")
    }

    func testNegativeTimesBecomeZero() {
        let odd = NowPlayingService.sanitized(info(duration: -1, elapsed: -30))
        XCTAssertEqual(odd.duration, 0)
        XCTAssertEqual(odd.elapsed, 0)
    }

    func testOrdinaryTrackIsUntouched() {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let track = NowPlayingService.sanitized(info(duration: 214, elapsed: 61, timestamp: t0))
        XCTAssertEqual(track.duration, 214)
        XCTAssertEqual(track.elapsed, 61)
        XCTAssertEqual(track.timestamp, t0)
    }

    func testAStreamWithNoLengthHasNowhereToSeek() {
        // A click on its bar asked for that fraction of nothing, and the stream went to 0:00.
        let stream = NowPlayingService.sanitized(info(duration: .infinity, elapsed: 600))
        XCTAssertFalse(stream.canSeek)
        XCTAssertFalse(NowPlayingService.sanitized(info(duration: .nan, elapsed: 0)).canSeek)
        XCTAssertFalse(NowPlayingService.sanitized(info(duration: -1, elapsed: 0)).canSeek)
        XCTAssertTrue(NowPlayingService.sanitized(info(duration: 214, elapsed: 61)).canSeek)
    }

    func testTheScrubberAndTheSkipsAskTheSameQuestion() {
        for duration in [TimeInterval.infinity, 0, 214] {
            let report = NowPlayingService.sanitized(info(duration: duration, elapsed: 0))
            XCTAssertEqual(report.supports.contains(.forward15), report.canSeek, "duration \(duration)")
            XCTAssertEqual(report.supports.contains(.back15), report.canSeek, "duration \(duration)")
        }
        XCTAssertFalse(NowPlayingInfo.canSeek(duration: .infinity), "the rule holds before sanitising too")
    }

    func testBrokenTimestampIsReplaced() {
        let broken = NowPlayingService.sanitized(info(duration: 200, elapsed: 1, timestamp: Date(timeIntervalSinceReferenceDate: .nan)))
        XCTAssertTrue(broken.timestamp.timeIntervalSinceReferenceDate.isFinite)
        XCTAssertTrue(broken.position(at: Date()).isFinite)
    }

    // MARK: - A title that reads right to left

    /// A long Hebrew or Arabic title opened on its last words, and its beginning scrolled in
    /// last: the marquee held every title at its left end and moved it left.
    func testATitleReadsTheWayItsFirstLetterDoes() {
        XCTAssertTrue(MarqueeText.isRightToLeft("שיר השירים"))
        XCTAssertTrue(MarqueeText.isRightToLeft("أغنية طويلة جدا"))
        XCTAssertTrue(MarqueeText.isRightToLeft("1984 — שיר"), "digits and dashes say nothing")
        XCTAssertTrue(MarqueeText.isRightToLeft("(«ليلى»)"))
        XCTAssertFalse(MarqueeText.isRightToLeft("Hello, שלום"), "the first letter decides")
        XCTAssertFalse(MarqueeText.isRightToLeft("Café del Mar"))
        XCTAssertFalse(MarqueeText.isRightToLeft("東京"), "Japanese reads left to right")
        XCTAssertFalse(MarqueeText.isRightToLeft(""))
        XCTAssertFalse(MarqueeText.isRightToLeft("2024 — 12"), "no letter at all")
        XCTAssertTrue(MarqueeText.isRightToLeft("\u{200F}1, 2, 3"), "a right-to-left mark")
    }

    // MARK: - What a player's script says

    /// The poll's script writes whole milliseconds, so no decimal separator is ever in them. It
    /// wrote seconds as a real, in the region's own notation, and a Mac whose region writes "٫"
    /// read every track as 0:00 long.
    func testAPlayersTimesAreReadAsMilliseconds() {
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds("213000"), 213)
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds("61500"), 61.5)
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds("0"), 0)
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds(" 1000 "), 1)
    }

    /// A real is still read, whichever separator it was written with: the script falls back to
    /// one for a length too long for an AppleScript integer.
    func testARealIsStillReadWithAnySeparator() {
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds("213.5"), 213.5)
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds("213,5"), 213.5)
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds("213\u{066B}5"), 213.5, "the Arabic decimal separator")
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds("6.0E+5"), 600_000)
    }

    func testWhatIsNotANumberIsNought() {
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds("missing value"), 0, "a stream with no length")
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds(""), 0)
        XCTAssertEqual(AppleScriptBackend.scriptedSeconds("inf"), 0)
    }

    // MARK: - The script queue's waits

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func press(_ kind: AppleScriptBackend.Press.Kind) -> AppleScriptBackend.Press {
        AppleScriptBackend.Press(kind: kind, player: AppleScriptBackend.musicID, source: "", at: t0)
    }

    func testAPressWaitingOnAPollThatAnsweredIsNotOutOfPatience() {
        let patience = AppleScriptBackend.pressPatience
        // The poll ahead held the queue for eight seconds, and the press began to run then.
        let freed = t0 + 8
        XCTAssertEqual(AppleScriptBackend.patienceStart(madeAt: t0, queueFreeAt: freed, stalledAt: nil), freed)
        XCTAssertTrue(AppleScriptBackend.stillWanted(press(.toggle), now: freed, queueFreeAt: freed),
                      "the poll's wait was the island's own")
        XCTAssertFalse(AppleScriptBackend.stillWanted(press(.toggle), now: freed + patience + 1, queueFreeAt: freed),
                       "the wait after it still counts")
    }

    func testAPressWaitingOnAPlayerThatDidNotAnswerStillRunsOutOfPatience() {
        let freed = t0 + 8
        let stalled = t0 + 4
        XCTAssertEqual(AppleScriptBackend.patienceStart(madeAt: t0, queueFreeAt: freed, stalledAt: stalled), t0)
        XCTAssertFalse(AppleScriptBackend.stillWanted(press(.toggle), now: freed, queueFreeAt: freed, stalledAt: stalled))
        XCTAssertTrue(AppleScriptBackend.stillWanted(press(.pause), now: freed, queueFreeAt: freed, stalledAt: stalled),
                      "a pause is never too late")
        XCTAssertEqual(AppleScriptBackend.patienceStart(madeAt: t0, queueFreeAt: freed, stalledAt: t0 - 1), freed,
                       "a stall before the press was made is not this press's wait")
    }

    func testPatienceNeverStartsBeforeThePressWasMade() {
        XCTAssertEqual(AppleScriptBackend.patienceStart(madeAt: t0, queueFreeAt: t0 - 5, stalledAt: nil), t0)
        XCTAssertEqual(AppleScriptBackend.patienceStart(madeAt: t0, queueFreeAt: nil, stalledAt: nil), t0)
    }

    func testOneSpotifyCoverFetchIsOutAtATime() {
        XCTAssertTrue(AppleScriptBackend.startsCoverFetch(hasCover: false, attempts: 0, inFlight: false))
        XCTAssertFalse(AppleScriptBackend.startsCoverFetch(hasCover: false, attempts: 0, inFlight: true),
                       "the poll after does not send another while the first is out")
        XCTAssertFalse(AppleScriptBackend.startsCoverFetch(hasCover: true, attempts: 0, inFlight: false))
        XCTAssertFalse(AppleScriptBackend.startsCoverFetch(hasCover: false, attempts: AppleScriptBackend.coverAttemptLimit,
                                                           inFlight: false))
    }
}
