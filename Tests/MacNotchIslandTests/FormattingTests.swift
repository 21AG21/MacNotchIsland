import XCTest
import SwiftUI
@testable import MacNotchIsland

final class FormattingTests: XCTestCase {
    func testMMSS() {
        XCTAssertEqual(TimeInterval(0).mmss, "0:00")
        XCTAssertEqual(TimeInterval(65.9).mmss, "1:05")
        XCTAssertEqual(TimeInterval(3600 + 62).mmss, "1:01:02")
    }

    func testTimerStringRoundsUp() {
        XCTAssertEqual(TimeInterval(300).timerString, "5:00")
        XCTAssertEqual(TimeInterval(299.2).timerString, "5:00")
        XCTAssertEqual(TimeInterval(0.4).timerString, "0:01")
    }

    func testTimerStateMath() {
        let end = Date().addingTimeInterval(120)
        var t = TimerState(label: "t", total: 120, endDate: end)
        XCTAssertEqual(t.remaining(at: end.addingTimeInterval(-30)), 30, accuracy: 0.001)
        XCTAssertEqual(t.progress(at: end.addingTimeInterval(-30)), 0.75, accuracy: 0.001)
        t.pausedRemaining = 45
        XCTAssertTrue(t.isPaused)
        XCTAssertEqual(t.remaining(at: Date.distantFuture), 45)
    }

    func testStopwatchElapsed() {
        let start = Date()
        var s = StopwatchState(startedAt: start, accumulated: 10)
        XCTAssertEqual(s.elapsed(at: start.addingTimeInterval(5)), 15, accuracy: 0.001)
        s.isRunning = false
        XCTAssertEqual(s.elapsed(at: start.addingTimeInterval(500)), 10)
    }

    func testDownloadProgress() {
        XCTAssertEqual(DownloadState(name: "a", bytes: 50, total: 200, app: "Safari").progress ?? -1, 0.25, accuracy: 0.001)
        XCTAssertNil(DownloadState(name: "a", bytes: 50, total: nil, app: "Chrome").progress)
        XCTAssertEqual(DownloadState(name: "a", bytes: 500, total: 200, app: "Safari").progress, 1)
    }

    func testBluetoothSummary() {
        XCTAssertEqual(BluetoothState(name: "", address: "", symbol: "", batteryLeft: 80, batteryRight: 60).summaryPercent, 60)
        XCTAssertEqual(BluetoothState(name: "", address: "", symbol: "", batterySingle: 42).summaryPercent, 42)
        XCTAssertNil(BluetoothState(name: "", address: "", symbol: "").summaryPercent)
    }

    func testHexColor() {
        XCTAssertNotNil(Color(hex: "#34C759"))
        XCTAssertNotNil(Color(hex: "34C759FF"))
        XCTAssertNil(Color(hex: "nope"))
        XCTAssertNil(Color(hex: "#12345"))
    }

    func testNowPlayingPositionInterpolation() {
        let t0 = Date()
        var info = NowPlayingInfo(title: "a", artist: "b", album: "", duration: 100, elapsed: 20, timestamp: t0,
                                  isPlaying: true, bundleID: nil, artwork: nil, artworkID: 0, accent: .white)
        XCTAssertEqual(info.position(at: t0.addingTimeInterval(10)), 30, accuracy: 0.001)
        XCTAssertEqual(info.position(at: t0.addingTimeInterval(500)), 100, "clamped to duration")
        info.isPlaying = false
        XCTAssertEqual(info.position(at: t0.addingTimeInterval(10)), 20, "paused position doesn't advance")
    }

    func testCalendarRelativeStart() {
        let now = Date()
        let c = CalendarState(title: "t", start: now.addingTimeInterval(5 * 60), end: now.addingTimeInterval(65 * 60), location: nil, joinURL: nil, tint: "blue")
        XCTAssertEqual(c.relativeStart(at: now), "in 5m")
        XCTAssertEqual(c.relativeStart(at: now.addingTimeInterval(6 * 60)), "Now")
        XCTAssertEqual(c.relativeStart(at: now.addingTimeInterval(70 * 60)), "Ended")
    }

    func testNotchGeometryOverrides() {
        let prefs = Preferences.shared
        prefs.notchWidthOverride = 222
        prefs.notchHeightOverride = 33
        guard let screen = NSScreen.main else { return }
        let g = NotchGeometry.detect(on: screen, prefs: prefs)
        XCTAssertEqual(g.notchWidth, 222)
        XCTAssertEqual(g.notchHeight, 33)
        prefs.notchWidthOverride = 0
        prefs.notchHeightOverride = 0
    }
}
