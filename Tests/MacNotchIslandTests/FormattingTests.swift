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

    /// A live stream reports an infinite duration and an unmeasured track a NaN position;
    /// `Int(Double)` traps on both, and on anything past Int's range, so the clock must not.
    func testClockSurvivesWhatPlayersReport() {
        XCTAssertEqual(TimeInterval.infinity.mmss, "0:00")
        XCTAssertEqual((-TimeInterval.infinity).mmss, "0:00")
        XCTAssertEqual(TimeInterval.nan.mmss, "0:00")
        XCTAssertEqual(TimeInterval(-5).mmss, "0:00")
        XCTAssertEqual(TimeInterval.greatestFiniteMagnitude.mmss, "99:59:59")
        XCTAssertEqual(TimeInterval.infinity.timerString, "0:00")
        XCTAssertEqual(TimeInterval.nan.timerString, "0:00")
        XCTAssertEqual(TimeInterval(1e300).timerString, "99:59:59")
        XCTAssertEqual(IslandAccessibility.playbackValue(position: .nan, duration: .infinity), "0 seconds",
                       "a stream with no length is its position alone")
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

    /// The pill's "in 5m" is "in 5 metres" read aloud, so the sentence VoiceOver gets has the
    /// same figure in words, with its singulars right.
    func testCalendarSpokenStart() {
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        func meeting(in seconds: TimeInterval) -> CalendarState {
            CalendarState(title: "t", start: now.addingTimeInterval(seconds), end: now.addingTimeInterval(seconds + 3600),
                          location: nil, joinURL: nil, tint: "blue")
        }
        XCTAssertEqual(meeting(in: 5 * 60).spokenStart(at: now), "in 5 minutes")
        XCTAssertEqual(meeting(in: 30).spokenStart(at: now), "in 1 minute")
        XCTAssertEqual(meeting(in: 61 * 60).spokenStart(at: now), "in 1 hour")
        XCTAssertEqual(meeting(in: 61 * 60).relativeStart(at: now), "in 1h", "the same figure as the pill's")
        XCTAssertEqual(meeting(in: 150 * 60).spokenStart(at: now), "in 2 hours")
        XCTAssertEqual(meeting(in: -60).spokenStart(at: now), "now")
        XCTAssertEqual(meeting(in: -7200).spokenStart(at: now), "ended")
        XCTAssertTrue(meeting(in: 1e300).relativeStart(at: now).hasPrefix("in "), "a start nobody could mean does not trap")
    }

    // MARK: - The region's decimal mark

    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    /// Settings wrote "0.35 s" on every Mac, and "150 %" where the island writes "82%".
    func testSettingsFiguresUseTheRegionsMarkAndTheIslandsPercent() {
        XCTAssertEqual(SettingsFormat.value(0.35, unit: "s", locale: english), "0.35 s")
        XCTAssertEqual(SettingsFormat.value(0.35, unit: "s", locale: german), "0,35 s")
        XCTAssertEqual(SettingsFormat.value(4, unit: "s", locale: german), "4,00 s")
        XCTAssertEqual(SettingsFormat.value(150, unit: "%", locale: english), "150%")
        XCTAssertEqual(SettingsFormat.value(149.6, unit: "%", locale: german), "150%")
        XCTAssertEqual(SettingsFormat.value(185, unit: "pt", locale: english), "185 pt", "every other unit keeps its space")
        XCTAssertEqual(SettingsFormat.value(3, unit: "", locale: english), "3")
    }

    func testTheMotionPanesFiguresUseTheRegionsMark() {
        let faithful = IslandMotion.Preset.faithful.tuning
        XCTAssertEqual(MotionPane.describe(.open, tuning: faithful, locale: english), "0.44 s, bounce 0.28")
        XCTAssertEqual(MotionPane.describe(.open, tuning: faithful, locale: german), "0,44 s, bounce 0,28")
        XCTAssertEqual(MotionPane.describe(.close, tuning: IslandMotion.Preset.instant.tuning, locale: german), "0,16 s, bounce 0,00")
    }

    /// The Clock app's stopwatch writes its tenths after the region's mark: "01:05,3" in German.
    func testTheStopwatchsTenthsFollowTheRegionsMark() {
        XCTAssertEqual(StopwatchExpandedView.format(65.34, locale: english), "01:05.3")
        XCTAssertEqual(StopwatchExpandedView.format(65.34, locale: german), "01:05,3")
        XCTAssertEqual(StopwatchExpandedView.format(3725.5, locale: german), "1:02:05,5")
        XCTAssertEqual(StopwatchExpandedView.format(65.34, showTenths: false, locale: german), "01:05", "no mark without tenths")
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

    /// The override can only widen the island, so the Width slider starts at the width the
    /// island already has, and its end there is Automatic rather than a figure that does nothing.
    func testTheWidthSliderStartsAtTheWidthTheIslandAlreadyHas() {
        XCTAssertEqual(NotchGeometry.widthOverride(185, automatic: 185), 0, "the slider's end is Automatic")
        XCTAssertEqual(NotchGeometry.widthOverride(150, automatic: 185), 0, "narrower than the notch changes nothing")
        XCTAssertEqual(NotchGeometry.widthOverride(222, automatic: 185), 222)

        guard let screen = NSScreen.main else { return }
        let prefs = Preferences.shared
        let saved = prefs.notchWidthOverride
        defer { prefs.notchWidthOverride = saved }
        prefs.notchWidthOverride = 0
        XCTAssertEqual(NotchGeometry.detect(on: screen, prefs: prefs).notchWidth, NotchGeometry.automaticWidth(on: screen),
                       "with no override the island is the width the slider starts at")
    }

    /// The Height slider ran from nothing, and every figure under the notch's own height did
    /// nothing at all — Width's fault, left behind on the slider under it. It gets Width's rule.
    func testTheHeightSliderStartsAtTheHeightTheIslandAlreadyHas() {
        XCTAssertEqual(NotchGeometry.heightOverride(32, automatic: 32), 0, "the slider's end is Automatic")
        XCTAssertEqual(NotchGeometry.heightOverride(12, automatic: 32), 0, "shorter than the notch changes nothing")
        XCTAssertEqual(NotchGeometry.heightOverride(0, automatic: 32), 0, "and Automatic stays Automatic")
        XCTAssertEqual(NotchGeometry.heightOverride(40, automatic: 32), 40)

        guard let screen = NSScreen.main else { return }
        let prefs = Preferences.shared
        let saved = prefs.notchHeightOverride
        defer { prefs.notchHeightOverride = saved }
        let automatic = NotchGeometry.automaticHeight(on: screen)
        prefs.notchHeightOverride = 0
        XCTAssertEqual(NotchGeometry.detect(on: screen, prefs: prefs).notchHeight, automatic,
                       "with no override the island is the height the slider starts at")
        prefs.notchHeightOverride = Double(automatic) - 10
        XCTAssertEqual(NotchGeometry.detect(on: screen, prefs: prefs).notchHeight, automatic,
                       "a figure under it, stored by an older build, leaves the island as it is")
        prefs.notchHeightOverride = Double(automatic) + 6
        XCTAssertEqual(NotchGeometry.detect(on: screen, prefs: prefs).notchHeight, automatic + 6,
                       "and one over it makes the island taller")
    }
}
