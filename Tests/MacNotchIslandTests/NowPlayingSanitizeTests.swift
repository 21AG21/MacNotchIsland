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

    func testBrokenTimestampIsReplaced() {
        let broken = NowPlayingService.sanitized(info(duration: 200, elapsed: 1, timestamp: Date(timeIntervalSinceReferenceDate: .nan)))
        XCTAssertTrue(broken.timestamp.timeIntervalSinceReferenceDate.isFinite)
        XCTAssertTrue(broken.position(at: Date()).isFinite)
    }
}
