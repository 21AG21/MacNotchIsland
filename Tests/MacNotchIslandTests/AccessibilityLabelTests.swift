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
        XCTAssertEqual(label(.timer(t)), "Timer, 4 minutes 59 seconds remaining")
        t.pausedRemaining = 60
        XCTAssertEqual(label(.timer(t)), "Timer, 1 minute remaining, paused")
        t.isFinished = true
        XCTAssertEqual(label(.timer(t)), "Timer, done")
    }

    func testStopwatch() {
        var s = StopwatchState(startedAt: now.addingTimeInterval(-130))
        XCTAssertEqual(label(.stopwatch(s)), "Stopwatch, 2 minutes 10 seconds elapsed")
        s.isRunning = false
        s.accumulated = 65
        XCTAssertEqual(label(.stopwatch(s)), "Stopwatch, 1 minute 5 seconds elapsed, paused")
    }

    func testCall() {
        let c = CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: now.addingTimeInterval(-130))
        XCTAssertEqual(label(.call(c)), "Call with FaceTime, 2 minutes 10 seconds")
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
        XCTAssertEqual(label(.calendar(c)), "Standup, in 5 minutes")
        XCTAssertEqual(label(.download(DownloadState(name: "Xcode.xip", bytes: 45, total: 100, app: "Safari"))),
                       "Downloading Xcode.xip, 45 percent")
        XCTAssertEqual(label(.download(DownloadState(name: "Xcode.xip", bytes: 100, total: 100, app: "Safari", isComplete: true))),
                       "Xcode.xip downloaded")
        XCTAssertEqual(label(.custom(CustomActivity(title: "Build", subtitle: "Running tests"))), "Build, Running tests")
        XCTAssertEqual(label(.custom(CustomActivity(title: "Build"))), "Build")
    }

    func testPlaybackValue() {
        XCTAssertEqual(IslandAccessibility.playbackValue(position: 65, duration: 200), "1 minute 5 seconds of 3 minutes 20 seconds")
        XCTAssertEqual(IslandAccessibility.playbackValue(position: 65, duration: 0), "1 minute 5 seconds")
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
                       "Timer, 3 minutes 59 seconds remaining")
        let call = CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: now)
        XCTAssertEqual(IslandAccessibility.compactLabel(for: .call(call), at: now.addingTimeInterval(125), micMuted: true),
                       "Call with FaceTime, 2 minutes 5 seconds, microphone muted")
    }

    /// The pill's clock digits are read as a time of day — "4:59" is one minute to five — and the
    /// cards already said their figures in words. The pill now says them the way its card does.
    func testThePillSaysItsFiguresTheWayItsCardDoes() {
        let running = TimerState(label: "Pasta", total: 300, endDate: now.addingTimeInterval(299.4))
        XCTAssertEqual(label(.timer(running)), "Timer, \(IslandAccessibility.spokenDuration(running.remaining(at: now).rounded(.up))) remaining",
                       "the timer card's own words, rounded up to the second on the digits")
        XCTAssertEqual(label(.timer(running)), "Timer, 5 minutes remaining")
        let recording = CustomActivity(title: "Recording", countsUpFrom: now.addingTimeInterval(-3725))
        XCTAssertEqual(label(.custom(recording)), "Recording, 1 hour 2 minutes 5 seconds")
        let soon = CalendarState(title: "Standup", start: now.addingTimeInterval(45), end: now.addingTimeInterval(20 * 60),
                                 location: nil, joinURL: nil, tint: "blue")
        XCTAssertEqual(label(.calendar(soon)), "Standup, in 1 minute")
        for spoken in [label(.timer(running)), label(.custom(recording)), label(.calendar(soon)),
                       label(.stopwatch(StopwatchState(startedAt: now.addingTimeInterval(-65)))),
                       IslandAccessibility.playbackValue(position: 65, duration: 200)] {
            XCTAssertNil(spoken.range(of: #"\d:\d"#, options: .regularExpression), "no clock digits in \(spoken)")
            XCTAssertNil(spoken.range(of: #"\d[mh]\b"#, options: .regularExpression), "no clipped units in \(spoken)")
        }
    }

    // The pill's timelines count their beats from the moment the figure counts from, so it is
    // redrawn as its digits change rather than up to a second later.

    func testThePillsBeatIsCountedFromTheFigure() {
        let timer = TimerState(label: "Pasta", total: 300, endDate: now.addingTimeInterval(299.3))
        XCTAssertEqual(PillClock.origin(of: .timer(timer)), timer.endDate)
        let stopwatch = StopwatchState(startedAt: now.addingTimeInterval(-10), accumulated: 65.4)
        XCTAssertEqual(PillClock.origin(of: .stopwatch(stopwatch))?.timeIntervalSince(now) ?? 0, -75.4, accuracy: 0.0001,
                       "where it would have started with nothing on it")
        let call = CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: now.addingTimeInterval(-42.7))
        XCTAssertEqual(PillClock.origin(of: .call(call)), call.startedAt)
        let standup = CalendarState(title: "Standup", start: now.addingTimeInterval(415), end: now.addingTimeInterval(1200),
                                    location: nil, joinURL: nil, tint: "blue")
        XCTAssertEqual(PillClock.origin(of: .calendar(standup)), standup.start)
        XCTAssertEqual(PillClock.origin(of: .custom(CustomActivity(title: "Recording", countsUpFrom: call.startedAt))), call.startedAt)
    }

    func testAFigureStandingStillKeepsNoBeat() {
        var paused = TimerState(label: "Pasta", total: 300, endDate: now.addingTimeInterval(299))
        paused.pausedRemaining = 60
        XCTAssertNil(PillClock.origin(of: .timer(paused)))
        var stopped = StopwatchState(startedAt: now)
        stopped.isRunning = false
        XCTAssertNil(PillClock.origin(of: .stopwatch(stopped)))
        XCTAssertNil(PillClock.origin(of: .unlock))
        XCTAssertEqual(PillClock.start(on: nil, every: 1, at: now), now, "no origin is the old schedule, from now")
        XCTAssertEqual(PillClock.start(on: now.addingTimeInterval(5), every: 0, at: now), now)
        XCTAssertEqual(PillClock.start(on: Date.distantFuture.addingTimeInterval(1e300), every: 1, at: now), now)
    }

    /// The schedule starts in the past, on a beat just after a turn of the figure, and every
    /// beat after it draws the figure that holds until the next one.
    func testEveryBeatLandsJustAfterTheFigureTurns() {
        let timer = TimerState(label: "Pasta", total: 300, endDate: now.addingTimeInterval(299.3))
        let start = PillClock.start(on: timer.endDate, every: 1, at: now)
        XCTAssertLessThanOrEqual(start, now, "never a schedule that starts in the future")
        XCTAssertGreaterThan(start, now.addingTimeInterval(-1))
        for beat in 0..<5 {
            let date = start.addingTimeInterval(Double(beat))
            let drawn = timer.remaining(at: date).timerString
            XCTAssertEqual(timer.remaining(at: date.addingTimeInterval(0.98)).timerString, drawn,
                           "the figure drawn on a beat is the figure until the next")
            XCTAssertNotEqual(timer.remaining(at: date.addingTimeInterval(-0.02)).timerString, drawn,
                              "and it turned just before the beat")
        }

        let call = CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: now.addingTimeInterval(-42.7))
        let callStart = PillClock.start(on: call.startedAt, every: 1, at: now)
        XCTAssertEqual(callStart.timeIntervalSince(call.startedAt), 42 + PillClock.lead, accuracy: 0.0001)

        let standup = CalendarState(title: "Standup", start: now.addingTimeInterval(415), end: now.addingTimeInterval(1200),
                                    location: nil, joinURL: nil, tint: "blue")
        let meetingStart = PillClock.start(on: standup.start, every: 30, at: now)
        XCTAssertEqual(standup.relativeStart(at: meetingStart), standup.relativeStart(at: meetingStart.addingTimeInterval(29.9)))
        XCTAssertEqual(meetingStart.timeIntervalSince(standup.start).truncatingRemainder(dividingBy: 30), -30 + PillClock.lead,
                       accuracy: 0.0001, "on the half-minute grid through the start")
    }
}
