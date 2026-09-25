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

    // MARK: - Brightness

    func testBrightnessIsReadRarelyWhileTheKeysAnnounceThemselves() {
        XCTAssertEqual(BrightnessMonitor.pollInterval(answersKeys: true, multiplier: 1), 2)
        XCTAssertEqual(BrightnessMonitor.pollInterval(answersKeys: false, multiplier: 1), 0.25,
                       "with macOS taking the keys, looking often is the only way to follow them")
        XCTAssertEqual(BrightnessMonitor.pollInterval(answersKeys: true, multiplier: 8), 16)
        XCTAssertEqual(BrightnessMonitor.pollInterval(answersKeys: false, multiplier: 4), 1)
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
