import XCTest
@testable import MacNotchIsland

/// The rules that decide how often the island wakes when nothing is happening: each poller's
/// interval, and the gates that switch a timer off entirely while it has nothing to do or
/// nobody to show it to. Asked directly, because none of them can be watched on a build machine
/// with no display, no music and nobody at it.
final class IdleWakeupTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Caps Lock

    func testCapsLockIsPolledOnceASecondAndSlowerForTheEnergyPolicy() {
        XCTAssertEqual(CapsLockMonitor.pollInterval(multiplier: 1), 1)
        XCTAssertEqual(CapsLockMonitor.pollInterval(multiplier: 2), 2)
        XCTAssertEqual(CapsLockMonitor.pollInterval(multiplier: 8), 8, "asleep, or with nobody at the Mac")
        XCTAssertEqual(CapsLockMonitor.pollInterval(multiplier: 0.5), 1, "never faster than the base, whatever it is handed")
    }

    /// The monitors only while they can hear something; the poll whenever they cannot.
    func testCapsLockListensForEventsOnlyWithThePermissionAndBothMonitors() {
        XCTAssertEqual(CapsLockMonitor.mode(trusted: true, monitorsInstalled: true), .events)
        XCTAssertEqual(CapsLockMonitor.mode(trusted: false, monitorsInstalled: true), .polling,
                       "a monitor left in place after the permission went hears nothing")
        XCTAssertEqual(CapsLockMonitor.mode(trusted: true, monitorsInstalled: false), .polling,
                       "a global monitor that was refused")
        XCTAssertEqual(CapsLockMonitor.mode(trusted: false, monitorsInstalled: false), .polling)
    }

    /// Listening for events used to mean nothing at all on a timer, so a revoked permission
    /// whose announcement went unheard left the key silent for the rest of the run.
    func testWhileListeningForEventsThePermissionIsStillLookedAtNowAndThen() {
        XCTAssertEqual(CapsLockMonitor.interval(for: .events, multiplier: 1), 30)
        XCTAssertEqual(CapsLockMonitor.interval(for: .events, multiplier: 8), 240, "slower for the energy policy")
        XCTAssertEqual(CapsLockMonitor.interval(for: .events, multiplier: 0), 30, "never faster than the base")
        XCTAssertEqual(CapsLockMonitor.interval(for: .polling, multiplier: 2), CapsLockMonitor.pollInterval(multiplier: 2))
        XCTAssertGreaterThan(CapsLockMonitor.interval(for: .events, multiplier: 1),
                             CapsLockMonitor.interval(for: .polling, multiplier: 1),
                             "the permission check is far rarer than the poll it stands in for")
    }

    // MARK: - Brightness

    /// Every two seconds whoever has the keys. With macOS taking them it used to be four times
    /// a second, to keep a level current that nothing here could announce or read.
    func testBrightnessIsReadEveryTwoSecondsAndSlowerForTheEnergyPolicy() {
        XCTAssertEqual(BrightnessMonitor.pollInterval(multiplier: 1), 2)
        XCTAssertEqual(BrightnessMonitor.pollInterval(multiplier: 8), 16)
        XCTAssertEqual(BrightnessMonitor.pollInterval(multiplier: 0.5), 2, "never faster than the base")
    }

    func testThePanelIsNotReadWhileMacOSHasTheKeys() {
        XCTAssertEqual(BrightnessMonitor.look(answering: false, wasAnswering: false, hasBaseline: true), .skip)
        XCTAssertEqual(BrightnessMonitor.look(answering: false, wasAnswering: true, hasBaseline: true), .skip,
                       "the tap has just gone: macOS draws its own bezel for the next change")
    }

    /// What the level did while macOS had the keys was macOS's to announce, and it did; the
    /// island taking them back is not a keypress.
    func testTheFirstReadingOnceTheIslandAnswersTheKeysIsABaseline() {
        XCTAssertEqual(BrightnessMonitor.look(answering: true, wasAnswering: false, hasBaseline: true), .baseline)
        XCTAssertEqual(BrightnessMonitor.look(answering: true, wasAnswering: true, hasBaseline: false), .baseline,
                       "nothing to compare with")
        XCTAssertEqual(BrightnessMonitor.look(answering: true, wasAnswering: true, hasBaseline: true), .compare)
    }

    // MARK: - What the media keys can answer

    func testANewOutputIsAskedAboutAgainAsItFinishesArriving() {
        let schedule = MediaKeyInterceptor.probeSchedule(afterChange: .output)
        XCTAssertEqual(schedule, [0, 2, 5, 15])
        XCTAssertEqual(schedule, schedule.sorted(), "backing off, never looking back")
        XCTAssertGreaterThan(schedule.last ?? 0, 2,
                             "a HomePod's level can take longer than the two seconds that used to be the last look")
        XCTAssertEqual(MediaKeyInterceptor.probeSchedule(afterChange: .displays), [0],
                       "a display is read once it is announced")
    }

    func testOnlyAnAnswerMissingSomethingWantedIsAskedForAgain() {
        typealias Caps = SystemHUDReplacement.Capabilities
        let everything = Caps(volume: true, mute: true, brightness: true, keyboard: true)
        XCTAssertFalse(MediaKeyInterceptor.needsReprobe(wanted: everything, answered: everything),
                       "a whole answer waits for something to be announced")
        XCTAssertTrue(MediaKeyInterceptor.needsReprobe(wanted: everything,
                                                       answered: Caps(volume: false, mute: true, brightness: true, keyboard: true)),
                      "an output whose level is not there yet, whose keys have gone back to macOS")
        XCTAssertTrue(MediaKeyInterceptor.needsReprobe(wanted: Caps(brightness: true), answered: Caps()))
        XCTAssertFalse(MediaKeyInterceptor.needsReprobe(wanted: Caps(brightness: true), answered: Caps(brightness: true)))
        XCTAssertFalse(MediaKeyInterceptor.needsReprobe(wanted: Caps(), answered: Caps()),
                       "a display the user switched off is not a question worth asking")
        XCTAssertFalse(MediaKeyInterceptor.needsReprobe(wanted: Caps(volume: true, mute: true), answered: everything),
                       "answering more than is wanted is not missing anything")
    }

    /// An output that never offers what is wanted — an HDMI display's sound — is not asked
    /// about every five seconds for the rest of the run: the watch timer asks only for a while
    /// after something else asked.
    func testTheWatchTimerAsksAgainForAMinuteAndThenLeavesIt() {
        XCTAssertTrue(MediaKeyInterceptor.watchAsksAgain(incomplete: true, sinceAsked: 5))
        XCTAssertTrue(MediaKeyInterceptor.watchAsksAgain(incomplete: true, sinceAsked: MediaKeyInterceptor.reprobeWindow - 1))
        XCTAssertFalse(MediaKeyInterceptor.watchAsksAgain(incomplete: true, sinceAsked: MediaKeyInterceptor.reprobeWindow))
        XCTAssertFalse(MediaKeyInterceptor.watchAsksAgain(incomplete: false, sinceAsked: 5),
                       "a whole answer waits for an announcement")
        XCTAssertGreaterThan(MediaKeyInterceptor.reprobeWindow, MediaKeyInterceptor.arrivalProbes.max() ?? 0,
                             "the timer outlasts the last of the arrival looks")
    }

    // MARK: - The rail's switches

    func testTheRailsSwitchesFollowTheEnergyPolicy() {
        XCTAssertEqual(SystemToggles.scaledPollInterval(multiplier: 1), SystemToggles.pollInterval)
        XCTAssertEqual(SystemToggles.scaledPollInterval(multiplier: 8), SystemToggles.pollInterval * 8)
        XCTAssertEqual(SystemToggles.scaledPollInterval(multiplier: 0), SystemToggles.pollInterval)
    }

    // MARK: - A menu over the island

    func testAMenusWindowsAreLookedForQuicklyOnlyUntilTheyAreFound() {
        XCTAssertEqual(IslandSpace.menuPollInterval(found: false), 0.05,
                       "every frame or so while the menu's own window may still be under the island")
        XCTAssertEqual(IslandSpace.menuPollInterval(found: true), 0.25, "then only for submenus")
        XCTAssertGreaterThan(IslandSpace.menuPollGiveUp, IslandSpace.menuPollInterval(found: true),
                             "the give-up is more than one look at either pace")
    }

    // MARK: - Timers

    private func running(_ id: String, endsIn seconds: TimeInterval) -> TimerEntry {
        TimerEntry(id: id, label: id, state: TimerState(label: id, total: 600, endDate: t0.addingTimeInterval(seconds)))
    }

    private func paused(_ id: String, left seconds: TimeInterval) -> TimerEntry {
        TimerEntry(id: id, label: id, state: TimerState(label: id, total: 600, endDate: t0.addingTimeInterval(seconds),
                                                        pausedRemaining: seconds))
    }

    func testTheTickerLooksAtTheSoonestEndAndNoSooner() {
        let timers = [running("a", endsIn: 300), running("b", endsIn: 90)]
        XCTAssertEqual(IslandTimer.nextTick(for: timers, now: t0), t0.addingTimeInterval(90),
                       "the ring is on the second, not up to a second and a bit after it")
    }

    func testNothingRunningIsNoTickerAtAll() {
        XCTAssertNil(IslandTimer.nextTick(for: [], now: t0))
        XCTAssertNil(IslandTimer.nextTick(for: [paused("a", left: 60)], now: t0), "a paused timer's time left never moves")
        var rung = running("b", endsIn: -5)
        rung.state.isFinished = true
        XCTAssertNil(IslandTimer.nextTick(for: [rung], now: t0), "and one that has rung has nothing more to happen")
    }

    func testARunningTimerOvertakingAPausedOneIsLookedAtWhenItDoes() {
        // Running with 100 s to go, paused with 30: the running one has the island from 70 s
        // on, which is before either rings, and `reprioritize` has to be asked then.
        let timers = [running("a", endsIn: 100), paused("b", left: 30)]
        let overtaking = IslandTimer.nextTick(for: timers, now: t0)?.timeIntervalSince(t0)
        XCTAssertEqual(overtaking ?? -1, 70 + IslandTimer.overtakeMargin, accuracy: 0.001)
        // The look that follows has only the ring left to wait for, so it cannot find the same
        // moment again and spin.
        XCTAssertEqual(IslandTimer.nextTick(for: timers, now: t0.addingTimeInterval(70 + 2 * IslandTimer.overtakeMargin)),
                       t0.addingTimeInterval(100))
    }

    func testARunningTimerAlreadyBelowAPausedOneWaitsOnlyForItsRing() {
        let timers = [running("a", endsIn: 20), paused("b", left: 30)]
        XCTAssertEqual(IslandTimer.nextTick(for: timers, now: t0), t0.addingTimeInterval(20))
    }

    // MARK: - Lyrics

    func testLyricsTickOnlyForSomebodyReadingThem() {
        XCTAssertTrue(LyricsService.ticks(running: true, playing: true, hasSyncedLines: true, viewers: 1, nobodyLooking: false))
        XCTAssertFalse(LyricsService.ticks(running: true, playing: true, hasSyncedLines: true, viewers: 0, nobodyLooking: false),
                       "the panel closed, or open on another section")
        XCTAssertFalse(LyricsService.ticks(running: true, playing: true, hasSyncedLines: true, viewers: 1, nobodyLooking: true),
                       "the view on screen at a lock screen, or on a display that has gone dark")
        XCTAssertFalse(LyricsService.ticks(running: true, playing: false, hasSyncedLines: true, viewers: 1, nobodyLooking: false))
        XCTAssertFalse(LyricsService.ticks(running: true, playing: true, hasSyncedLines: false, viewers: 1, nobodyLooking: false))
        XCTAssertFalse(LyricsService.ticks(running: false, playing: true, hasSyncedLines: true, viewers: 1, nobodyLooking: false))
    }

    // MARK: - The system audio tap

    func testTheTapListensOnlyForBarsOnScreen() {
        XCTAssertTrue(AudioLevelTap.shouldRun(wanted: true, playing: true, animationsPaused: false, viewers: 1))
        XCTAssertFalse(AudioLevelTap.shouldRun(wanted: true, playing: true, animationsPaused: false, viewers: 0),
                       "the island hidden, or showing something else")
        XCTAssertTrue(AudioLevelTap.shouldRun(wanted: true, playing: true, animationsPaused: false, viewers: 0, lingering: true),
                      "the pill's bars giving way to the panel's are not a reason to tear it down")
        XCTAssertFalse(AudioLevelTap.shouldRun(wanted: true, playing: true, animationsPaused: true, viewers: 1),
                       "bars that are not moving have nothing to follow")
        XCTAssertFalse(AudioLevelTap.shouldRun(wanted: true, playing: false, animationsPaused: false, viewers: 1))
        XCTAssertFalse(AudioLevelTap.shouldRun(wanted: false, playing: true, animationsPaused: false, viewers: 1))
    }
}
