import XCTest
import SwiftUI
@testable import MacNotchIsland

/// The compact pill is combined into a single accessibility element, so its spoken label is the
/// only description a screen reader gets for the whole activity.
final class AccessibilityLabelTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func info(title: String, artist: String) -> NowPlayingInfo {
        NowPlayingInfo(title: title, artist: artist, album: "", duration: 200, elapsed: 10, timestamp: now,
                       isPlaying: true, bundleID: nil, artwork: nil, artworkID: 0, accent: .white)
    }

    private func label(_ content: ActivityContent) -> String {
        IslandAccessibility.compactLabel(for: content, at: now)
    }

    func testNowPlaying() {
        XCTAssertEqual(label(.nowPlaying(info(title: "Alright", artist: "Kendrick Lamar"))),
                       "Now Playing, Alright by Kendrick Lamar")
        XCTAssertEqual(label(.nowPlaying(info(title: "Untitled", artist: ""))), "Now Playing, Untitled")
        XCTAssertEqual(label(.nowPlaying(info(title: "", artist: ""))), "Now Playing, Not Playing")
    }

    func testTimer() {
        var t = TimerState(label: "Pasta", total: 300, endDate: now.addingTimeInterval(299))
        XCTAssertEqual(label(.timer(t)), "Timer, 4:59 remaining")
        t.pausedRemaining = 60
        XCTAssertEqual(label(.timer(t)), "Timer, 1:00 remaining, paused")
        t.isFinished = true
        XCTAssertEqual(label(.timer(t)), "Timer, done")
    }

    func testStopwatch() {
        var s = StopwatchState(startedAt: now.addingTimeInterval(-130))
        XCTAssertEqual(label(.stopwatch(s)), "Stopwatch, 2:10 elapsed")
        s.isRunning = false
        s.accumulated = 65
        XCTAssertEqual(label(.stopwatch(s)), "Stopwatch, 1:05 elapsed, paused")
    }

    func testCall() {
        let c = CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: now.addingTimeInterval(-130))
        XCTAssertEqual(label(.call(c)), "Call with FaceTime, 2:10")
    }

    func testBatteryAndBluetooth() {
        XCTAssertEqual(label(.battery(BatteryState(percent: 18, isCharging: false, isPluggedIn: false, event: .low))),
                       "Battery, 18 percent")
        XCTAssertEqual(label(.battery(BatteryState(percent: 80, isCharging: true, isPluggedIn: true, event: .pluggedIn))),
                       "Battery charging, 80 percent")
        XCTAssertEqual(label(.bluetooth(BluetoothState(name: "AirPods Pro", address: "a", symbol: "airpods",
                                                       batteryLeft: 80, batteryRight: 60))),
                       "AirPods Pro connected, 60 percent battery")
        XCTAssertEqual(label(.bluetooth(BluetoothState(name: "Magic Mouse", address: "b", symbol: "magicmouse"))),
                       "Magic Mouse connected")
        XCTAssertEqual(label(.bluetooth(BluetoothState(name: "Beats", address: "c", symbol: "headphones", isConnected: false))),
                       "Beats disconnected")
    }

    func testHUDFocusAndSimpleStates() {
        XCTAssertEqual(label(.hud(LevelHUD(kind: .volume, level: 0.4))), "Volume, 40 percent")
        XCTAssertEqual(label(.hud(LevelHUD(kind: .volume, level: 0.4, isMuted: true))), "Volume muted")
        XCTAssertEqual(label(.hud(LevelHUD(kind: .brightness, level: 0.655))), "Brightness, 66 percent")
        // A key the island took and could do nothing with says so, for the kind of key it was.
        var noVolume = LevelHUD(kind: .volume, level: 0)
        noVolume.isUnavailable = true
        noVolume.device = "LG UltraFine"
        XCTAssertEqual(label(.hud(noVolume)), "Volume is not set here, LG UltraFine")
        var noBrightness = LevelHUD(kind: .brightness, level: 0)
        noBrightness.isUnavailable = true
        XCTAssertEqual(label(.hud(noBrightness)), "Brightness is not set here",
                       "a display that will not be set is not a display turned down")
        // The pill says it too, not only VoiceOver: the dash on its own means "no number",
        // where this means "not from here", and the slot is wide enough for the words.
        XCTAssertEqual(LevelHUD.readout(noVolume), "\u{2014}")
        XCTAssertEqual(LevelHUD.unavailableHint(noVolume), "Set on the device")
        XCTAssertEqual(LevelHUD.unavailableHint(noBrightness), "Set on the display")
        XCTAssertGreaterThan(ActivityContent.hud(noVolume).compactWidths.trailing,
                             ActivityContent.hud(LevelHUD(kind: .volume, level: 0.4)).compactWidths.trailing,
                             "the words need more room than the bar they stand in for")

        XCTAssertEqual(label(.focus(FocusState(name: "Work", symbol: "moon.fill", isOn: true, tint: "indigo"))),
                       "Work Focus on")
        XCTAssertEqual(label(.silent(SilentState(isSilent: true))), "Silent mode on")
        XCTAssertEqual(label(.unlock), "Mac unlocked")
    }

    func testCalendarDownloadAndCustom() {
        let c = CalendarState(title: "Standup", start: now.addingTimeInterval(5 * 60), end: now.addingTimeInterval(20 * 60),
                              location: nil, joinURL: nil, tint: "blue")
        XCTAssertEqual(label(.calendar(c)), "Standup, in 5m")
        XCTAssertEqual(label(.download(DownloadState(name: "Xcode.xip", bytes: 45, total: 100, app: "Safari"))),
                       "Downloading Xcode.xip, 45 percent")
        XCTAssertEqual(label(.download(DownloadState(name: "Xcode.xip", bytes: 100, total: 100, app: "Safari", isComplete: true))),
                       "Xcode.xip downloaded")
        XCTAssertEqual(label(.custom(CustomActivity(title: "Build", subtitle: "Running tests"))), "Build, Running tests")
        XCTAssertEqual(label(.custom(CustomActivity(title: "Build"))), "Build")
    }

    func testPlaybackValue() {
        XCTAssertEqual(IslandAccessibility.playbackValue(position: 65, duration: 200), "1:05 of 3:20")
        XCTAssertEqual(IslandAccessibility.playbackValue(position: 65, duration: 0), "1:05")
    }

    func testSpokenDuration() {
        XCTAssertEqual(IslandAccessibility.spokenDuration(0), "0 seconds")
        XCTAssertEqual(IslandAccessibility.spokenDuration(1), "1 second")
        XCTAssertEqual(IslandAccessibility.spokenDuration(60), "1 minute")
        XCTAssertEqual(IslandAccessibility.spokenDuration(65), "1 minute 5 seconds")
        XCTAssertEqual(IslandAccessibility.spokenDuration(252), "4 minutes 12 seconds")
        XCTAssertEqual(IslandAccessibility.spokenDuration(299.4), "4 minutes 59 seconds")
        XCTAssertEqual(IslandAccessibility.spokenDuration(3600), "1 hour")
        XCTAssertEqual(IslandAccessibility.spokenDuration(3725), "1 hour 2 minutes 5 seconds")
        XCTAssertEqual(IslandAccessibility.spokenDuration(-5), "0 seconds")
        XCTAssertEqual(IslandAccessibility.spokenDuration(.infinity), "0 seconds")
    }

    func testShelf() {
        XCTAssertEqual(label(.shelf(ShelfState(count: 1, latestName: "a.png"))), "Shelf, 1 item")
        XCTAssertEqual(label(.shelf(ShelfState(count: 3, latestName: "a.png"))), "Shelf, 3 items")
    }

    // The rail's sliders are announced with a label and a percentage, which is only half of a
    // control: a value that cannot be changed without a pointer is a value read out to
    // somebody who cannot reach it. These are the arithmetic behind increment and decrement.

    func testASliderTheVoiceOverUserCanActuallyMove() {
        XCTAssertEqual(IslandSlider.stepped(from: 0.5, up: true), 0.5625, accuracy: 0.0001)
        XCTAssertEqual(IslandSlider.stepped(from: 0.5, up: false), 0.4375, accuracy: 0.0001)
        XCTAssertEqual(IslandSlider.adjustStep, GestureRouter.keyStep, accuracy: 0.0001,
                       "one press is one notch of the volume keys, not a second idea of a step")
    }

    func testAStepAtEitherEndOfTheTrackStopsAtTheEnd() {
        XCTAssertEqual(IslandSlider.stepped(from: 1, up: true), 1, accuracy: 0.0001)
        XCTAssertEqual(IslandSlider.stepped(from: 0, up: false), 0, accuracy: 0.0001)
        XCTAssertEqual(IslandSlider.stepped(from: 0.97, up: true), 1, accuracy: 0.0001,
                       "a press near the top lands on the top rather than past it")
        XCTAssertEqual(IslandSlider.stepped(from: 0.03, up: false), 0, accuracy: 0.0001)
    }

    func testAStepUpFromSilenceIsSomethingYouCanHear() {
        let first = IslandSlider.stepped(from: 0, up: true)
        XCTAssertEqual(first, GestureRouter.keyStep, accuracy: 0.0001)
        XCTAssertGreaterThan(first, 0.03, "a first press that cannot be heard reads as a press that did nothing")
        XCTAssertLessThan(first, 0.15, "and it is one notch, not a jump across the room")
    }
}
