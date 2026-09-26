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

    func testTheAirPodsCardKeepsItsButtonWhereVoiceOverCanReachIt() {
        // The row was one ignored element, with Connect / Disconnect folded into it.
        let pods = BluetoothState(name: "AirPods Pro", address: "a", symbol: "airpods", batteryLeft: 92, batteryRight: 88)
        XCTAssertTrue(BluetoothExpandedView.offersConnection(pods))
        XCTAssertFalse(BluetoothExpandedView.readsAsOneElement(pods), "a container, so the button inside is its own element")
        XCTAssertEqual(BluetoothExpandedView.connectionLabel(for: pods), "Disconnect AirPods Pro")
        XCTAssertEqual(BluetoothExpandedView.accessibilitySummary(for: pods), "AirPods Pro connected, left 92 percent, right 88 percent",
                       "and the sentence is the container's label, without the button's words in it")

        let beats = BluetoothState(name: "Beats", address: "c", symbol: "headphones", isConnected: false)
        XCTAssertEqual(BluetoothExpandedView.connectionLabel(for: beats), "Connect Beats")

        let unknown = BluetoothState(name: "Speaker", address: "", symbol: "hifispeaker")
        XCTAssertFalse(BluetoothExpandedView.offersConnection(unknown), "no address, no button")
        XCTAssertTrue(BluetoothExpandedView.readsAsOneElement(unknown), "and nothing in the sentence to lose")
    }

    /// A container reads its label and then what is in it, so the card with a button in it was
    /// read twice: the sentence, then the name, "Connected" and each reading on its own.
    func testTheAirPodsCardIsReadOnceAsASentenceAndAButton() {
        let pods = BluetoothState(name: "AirPods Pro", address: "a", symbol: "airpods", batteryLeft: 92, batteryRight: 88)
        XCTAssertTrue(BluetoothExpandedView.hidesItsWords(pods), "the words are the label already")
        let unknown = BluetoothState(name: "Speaker", address: "", symbol: "hifispeaker")
        for state in [pods, unknown] {
            XCTAssertEqual(BluetoothExpandedView.hidesItsWords(state), !BluetoothExpandedView.readsAsOneElement(state),
                           "hidden exactly where the row is a container: \(state.name)")
        }
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

    // The pill's sentence is written from inside a timeline, because the pill's body does not
    // run again as its digits change: written once, it went on saying "4:59 remaining" for
    // minutes. `speechCadence` is how often that timeline turns for each kind of content.

    func testThePillsSentenceTurnsAsOftenAsItsFigureDoes() {
        let running = TimerState(label: "Pasta", total: 300, endDate: now.addingTimeInterval(299))
        XCTAssertEqual(IslandAccessibility.speechCadence(for: .timer(running)), TimerRing.cadence)
        XCTAssertEqual(IslandAccessibility.speechCadence(for: .stopwatch(StopwatchState(startedAt: now))), 1)
        let call = CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: now)
        XCTAssertEqual(IslandAccessibility.speechCadence(for: .call(call)), 1)
        XCTAssertEqual(IslandAccessibility.speechCadence(for: .custom(CustomActivity(title: "Recording", countsUpFrom: now))), 1)
        let standup = CalendarState(title: "Standup", start: now.addingTimeInterval(5 * 60), end: now.addingTimeInterval(20 * 60),
                                    location: nil, joinURL: nil, tint: "blue")
        XCTAssertEqual(IslandAccessibility.speechCadence(for: .calendar(standup)), 30,
                       "\"in 5m\" moves by the minute, on the beat the pill redraws it on")
    }

    func testASentenceThatStandsStillIsNotRedrawn() {
        var paused = TimerState(label: "Pasta", total: 300, endDate: now.addingTimeInterval(299))
        paused.pausedRemaining = 60
        XCTAssertNil(IslandAccessibility.speechCadence(for: .timer(paused)), "a paused timer says the same thing until it is resumed")
        var done = TimerState(label: "Pasta", total: 300, endDate: now)
        done.isFinished = true
        XCTAssertNil(IslandAccessibility.speechCadence(for: .timer(done)))
        var stopped = StopwatchState(startedAt: now)
        stopped.isRunning = false
        XCTAssertNil(IslandAccessibility.speechCadence(for: .stopwatch(stopped)))
        XCTAssertNil(IslandAccessibility.speechCadence(for: .custom(CustomActivity(title: "Build", subtitle: "Running tests"))))
        XCTAssertNil(IslandAccessibility.speechCadence(for: .battery(BatteryState(percent: 80, isCharging: true,
                                                                                    isPluggedIn: true, event: .pluggedIn))))
        XCTAssertNil(IslandAccessibility.speechCadence(for: .unlock))
    }

    /// Wherever the sentence turns, what it says at the turn is the time then — which is what
    /// the timeline hands it, and what the sentence written at the body's time was not.
    func testTheSentenceATurnLaterSaysTheTimeThen() {
        let running = TimerState(label: "Pasta", total: 300, endDate: now.addingTimeInterval(299))
        XCTAssertEqual(IslandAccessibility.compactLabel(for: .timer(running), at: now.addingTimeInterval(60)),
                       "Timer, 3:59 remaining")
        let call = CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: now)
        XCTAssertEqual(IslandAccessibility.compactLabel(for: .call(call), at: now.addingTimeInterval(125), micMuted: true),
                       "Call with FaceTime, 2:05, microphone muted")
    }
}
