import AppKit
import XCTest
@testable import MacNotchIsland

/// A transport command and the backend's report of it race; these pin down which one the
/// island believes and for how long.
final class NowPlayingReconcileTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func info(_ title: String = "Song", playing: Bool, elapsed: TimeInterval = 30, at date: Date? = nil) -> NowPlayingInfo {
        NowPlayingInfo(title: title, artist: "Band", album: "", duration: 200, elapsed: elapsed, timestamp: date ?? t0,
                       isPlaying: playing, bundleID: "com.apple.Music", artwork: nil, artworkID: 0, accent: .white)
    }

    /// A cover found for a track a player never gave one for has to survive that player's
    /// next report, or it would flash on and off once a second.
    func testAFoundCoverSurvivesTheNextReport() {
        let cover = NSImage(size: NSSize(width: 10, height: 10))
        var withCover = info(playing: true)
        withCover.artwork = cover
        withCover.artworkID = 7
        withCover.accent = .systemPink

        let bare = info(playing: true, elapsed: 31)
        let result = NowPlayingService.reconcile(incoming: bare, current: withCover, optimistic: nil, now: t0 + 1)
        XCTAssertTrue(result.artwork === cover, "the same track keeps the cover we found for it")
        XCTAssertEqual(result.artworkID, 7)
        XCTAssertEqual(result.elapsed, 31, "and the report is believed about everything else")

        let nextTrack = info("Another", playing: true)
        let switched = NowPlayingService.reconcile(incoming: nextTrack, current: withCover, optimistic: nil, now: t0 + 1)
        XCTAssertNil(switched.artwork, "a different track does not inherit it")
    }

    /// A player that does hand over its own artwork always wins.
    func testAPlayersOwnCoverIsNeverReplaced() {
        let mine = NSImage(size: NSSize(width: 10, height: 10))
        let theirs = NSImage(size: NSSize(width: 20, height: 20))
        var current = info(playing: true)
        current.artwork = mine
        var incoming = info(playing: true, elapsed: 31)
        incoming.artwork = theirs
        let result = NowPlayingService.reconcile(incoming: incoming, current: current, optimistic: nil, now: t0 + 1)
        XCTAssertTrue(result.artwork === theirs)
    }

    func testStaleReportInsideWindowKeepsTheUsersState() {
        let current = info(playing: false, elapsed: 30)                       // user just paused
        let pending = NowPlayingService.Optimistic(isPlaying: false, elapsed: nil, at: t0, until: t0 + 1.2)
        let stale = info(playing: true, elapsed: 30)                          // backend has not caught up
        let result = NowPlayingService.reconcile(incoming: stale, current: current, optimistic: pending, now: t0 + 0.3)
        XCTAssertFalse(result.isPlaying)
        XCTAssertEqual(result.elapsed, 30, accuracy: 0.01, "paused: the clock stays where the user left it")
    }

    func testReportAfterWindowIsBelieved() {
        let current = info(playing: false)
        let pending = NowPlayingService.Optimistic(isPlaying: false, elapsed: nil, at: t0, until: t0 + 1.2)
        let late = info(playing: true)
        XCTAssertTrue(NowPlayingService.reconcile(incoming: late, current: current, optimistic: pending, now: t0 + 2).isPlaying)
    }

    func testDifferentTrackIsAlwaysBelieved() {
        let current = info(playing: false)
        let pending = NowPlayingService.Optimistic(isPlaying: false, elapsed: nil, at: t0, until: t0 + 1.2)
        let next = info("Other", playing: true)
        XCTAssertTrue(NowPlayingService.reconcile(incoming: next, current: current, optimistic: pending, now: t0 + 0.1).isPlaying)
    }

    func testAgreementEndsTheWindowEarly() {
        let pending = NowPlayingService.Optimistic(isPlaying: false, elapsed: nil, at: t0, until: t0 + 1.2)
        XCTAssertTrue(NowPlayingService.agrees(info(playing: false), with: pending, now: t0))
        XCTAssertFalse(NowPlayingService.agrees(info(playing: true), with: pending, now: t0))
        let seek = NowPlayingService.Optimistic(isPlaying: nil, elapsed: 90, at: t0, until: t0 + 1.2)
        XCTAssertTrue(NowPlayingService.agrees(info(playing: true, elapsed: 90.4), with: seek, now: t0))
        XCTAssertFalse(NowPlayingService.agrees(info(playing: true, elapsed: 30), with: seek, now: t0))
    }

    func testSeekIsNotUndoneByAStaleElapsedTime() {
        let current = info(playing: true, elapsed: 90, at: t0)                // user just seeked to 1:30
        let pending = NowPlayingService.Optimistic(isPlaying: nil, elapsed: 90, at: t0, until: t0 + 1.2)
        let stale = info(playing: true, elapsed: 30, at: t0)
        let result = NowPlayingService.reconcile(incoming: stale, current: current, optimistic: pending, now: t0 + 0.2)
        XCTAssertEqual(result.position(at: t0 + 0.2), 90.2, accuracy: 0.05, "the seek target, advanced by the time since")
    }

    // MARK: - A paused track the limit has taken away

    func testThePausedTrackTheLimitTookAwayDoesNotComeBackOnTheNextReport() {
        // The helper repeats the same paused track every five seconds; believing it put the
        // card back five seconds after "Keep paused music for" had removed it, for good.
        let dismissed = info(playing: false)
        XCTAssertTrue(NowPlayingService.staysDismissed(info(playing: false, elapsed: 30), dismissed: dismissed))
    }

    func testPlayingItAgainOrAnotherTrackIsNews() {
        let dismissed = info(playing: false)
        XCTAssertFalse(NowPlayingService.staysDismissed(info(playing: true), dismissed: dismissed),
                       "pressing play brings the card back")
        XCTAssertFalse(NowPlayingService.staysDismissed(info("Another", playing: false), dismissed: dismissed),
                       "a different track, even paused, is a different card")
        XCTAssertFalse(NowPlayingService.staysDismissed(info(playing: false), dismissed: nil),
                       "and nothing dismissed holds nothing back")
    }

    // MARK: - Whether a backend is still worth listening to

    func testABackendThatHasGoneQuietStopsClaimingToBeHealthy() {
        // The fault this replaces was a one-way latch: a backend that answered once kept the
        // credit for it until the app was relaunched, and held every fallback shut behind it.
        // A backend answering once and then going silent is exactly how this breaks in the
        // wild, on the macOS point release that moves MediaRemote.
        let now = Date()
        XCTAssertTrue(BackendHealth.isFresh(now.addingTimeInterval(-5), now: now, within: 12))
        XCTAssertFalse(BackendHealth.isFresh(now.addingTimeInterval(-30), now: now, within: 12))
        XCTAssertFalse(BackendHealth.isFresh(nil, now: now, within: 12), "never heard from is not fresh")
    }

    func testAClockNudgedBackwardsDoesNotKillAWorkingBackend() {
        // Time sync moving the clock a second must not read as a death.
        let now = Date()
        XCTAssertTrue(BackendHealth.isFresh(now.addingTimeInterval(3), now: now, within: 12))
    }

    func testASleepIsNotSilenceTheHelperChose() {
        // An hour asleep leaves the helper's last message an hour old the moment the lid opens.
        // The watchdog took that for a wedged helper and killed a healthy one on every wake,
        // and let AppleScript at Music and Spotify while it was down.
        let now = Date()
        let beforeSleep = now.addingTimeInterval(-3600)
        XCTAssertTrue(AdapterBackend.isOverdue(lastMessage: beforeSleep, wokeAt: nil, now: now, within: 12),
                      "with no wake, an hour of silence is a helper gone quiet")
        XCTAssertFalse(AdapterBackend.isOverdue(lastMessage: beforeSleep, wokeAt: now.addingTimeInterval(-2), now: now, within: 12),
                       "two seconds after a wake it has not had its chance to speak")
        XCTAssertTrue(AdapterBackend.isOverdue(lastMessage: beforeSleep, wokeAt: now.addingTimeInterval(-13), now: now, within: 12),
                      "a whole silence window after the wake, it has")
        XCTAssertFalse(AdapterBackend.isOverdue(lastMessage: now.addingTimeInterval(-5), wokeAt: nil, now: now, within: 12),
                       "a helper that spoke a moment ago is answering, wake or none")
        XCTAssertTrue(AdapterBackend.isOverdue(lastMessage: nil, wokeAt: now, now: now, within: 12),
                      "and a wake is no reason to wait for a helper there is not")
    }

    func testAWatchdogKeptFromLookingHasSeenASleep() {
        // The wake notification can come after the watchdog's first look, so the watchdog also
        // notices for itself that it has not been running.
        let now = Date()
        XCTAssertFalse(AdapterBackend.missedItsLooks(lastCheck: now.addingTimeInterval(-2), now: now, window: 12), "a look on time")
        XCTAssertTrue(AdapterBackend.missedItsLooks(lastCheck: now.addingTimeInterval(-3600), now: now, window: 12))
        XCTAssertFalse(AdapterBackend.missedItsLooks(lastCheck: nil, now: now, window: 12), "the first look has nothing to go by")
    }

    func testDeathsAreCountedAsARateRatherThanForever() {
        // A lifetime budget of five is spent by a helper that dies once a day, after five days
        // of uptime — and the island then stays dark for the rest of the run. A rate forgives
        // the slow drip and still catches the crash loop the budget was written for.
        let now = Date()
        let onceADay = (1...6).map { now.addingTimeInterval(-Double($0) * 86_400) }
        XCTAssertFalse(BackendHealth.hasBlownBudget(onceADay, endingAt: now, window: 300, budget: 5),
                       "six deaths spread over six days is not a crash loop")
        let crashLoop = (1...6).map { now.addingTimeInterval(-Double($0) * 10) }
        XCTAssertTrue(BackendHealth.hasBlownBudget(crashLoop, endingAt: now, window: 300, budget: 5),
                      "six deaths in a minute is")
    }

    func testOnlyTheFailuresInsideTheWindowAreCountedAgainstIt() {
        let now = Date()
        let mixed = [now.addingTimeInterval(-10), now.addingTimeInterval(-400), now.addingTimeInterval(-20)]
        XCTAssertEqual(BackendHealth.recentFailures(mixed, endingAt: now, window: 300).count, 2)
    }

    func testTheDeathOfAHelperWeHaveAlreadyReplacedIsNotOurs() {
        // Two stop/start cycles in quick succession could leave the older helper's termination
        // clearing the handle to the newer one — which then left the newer one alive with
        // nobody holding it, feeding the island for the rest of the session.
        let held = Process()
        let older = Process()
        XCTAssertTrue(AdapterBackend.isTheHelperWeHold(held, held: held))
        XCTAssertFalse(AdapterBackend.isTheHelperWeHold(older, held: held), "an older one that has since been replaced")
        XCTAssertFalse(AdapterBackend.isTheHelperWeHold(nil, held: held))
        XCTAssertFalse(AdapterBackend.isTheHelperWeHold(held, held: nil))
    }

    // MARK: - What the Settings pane says about each backend

    func testABackendIsLiveOnlyWhileItAnswersWithATrack() {
        XCTAssertEqual(NowPlayingService.backendHealth(available: true, answering: true, deliveringTrack: true, outranked: false), .live)
        XCTAssertEqual(NowPlayingService.backendHealth(available: true, answering: true, deliveringTrack: false, outranked: false), .idle,
                       "answering with no track is a quiet Mac, not a fault")
        XCTAssertEqual(NowPlayingService.backendHealth(available: true, answering: false, deliveringTrack: false, outranked: false), .givenUp)
    }

    func testATrackFromABackendThatHasGoneQuietIsOldNews() {
        // The pair cannot arise from the backends as written, and the rule must still read it
        // the safe way round: "not answering" is the fact the pane exists to show.
        XCTAssertEqual(NowPlayingService.backendHealth(available: true, answering: false, deliveringTrack: true, outranked: false), .givenUp)
    }

    func testAnOutrankedBackendIsStandingByRatherThanBroken() {
        // MediaRemote's freshness lapses fifteen seconds after the last track change while the
        // helper does all the work. Read on its own it would say "not answering" on every Mac
        // where the helper works, which is every Mac this pane was written for.
        XCTAssertEqual(NowPlayingService.backendHealth(available: true, answering: false, deliveringTrack: false, outranked: true), .standingBy)
        XCTAssertEqual(NowPlayingService.backendHealth(available: true, answering: true, deliveringTrack: true, outranked: true), .standingBy,
                       "even one that would otherwise be live: only one source feeds the card")
    }

    func testAHelperThisMacCannotRunIsNeverAnythingElse() {
        XCTAssertEqual(NowPlayingService.backendHealth(available: false, answering: true, deliveringTrack: true, outranked: false), .unavailable)
        XCTAssertEqual(NowPlayingService.backendHealth(available: false, answering: false, deliveringTrack: false, outranked: true), .unavailable,
                       "not standing by either: there is nothing to stand by for")
    }

    // MARK: - Whether a wake has to rebuild the island
    //
    // Not a Now Playing rule. It lives here because the complaint it answers is the one the
    // backend-health rule above answers: an island, or a card, that goes blank after a sleep
    // and says nothing about why. The two rules went in together, both as pure functions so
    // a build machine with no notch and nothing playing can still pin them, and the tests
    // that pin them belong side by side for the same reason the rules do.

    private let builtIn: Set<String> = ["1|3024x1964|37"]
    private let builtInAndExternal: Set<String> = ["1|3024x1964|37", "2|2560x1440|0"]

    func testAWakeThatChangedNothingDoesNotRebuild() {
        // A rebuild nobody needed is a flicker on every lid-open, and a check that runs on
        // every wake earns its keep by finding nothing wrong nearly every time.
        XCTAssertFalse(AppDelegate.wakeNeedsRebuild(screensNow: builtIn, screensBefore: builtIn, panelsOnScreen: 1))
        XCTAssertFalse(AppDelegate.wakeNeedsRebuild(screensNow: builtInAndExternal, screensBefore: builtInAndExternal, panelsOnScreen: 2))
    }

    func testADisplayThatCameOrWentWhileAsleepRebuilds() {
        // The same judgement the screen-parameters path makes, asked by the wake path too:
        // a display plugged in or pulled out while the lid was closed has no other announcer.
        XCTAssertTrue(AppDelegate.wakeNeedsRebuild(screensNow: builtInAndExternal, screensBefore: builtIn, panelsOnScreen: 1))
        XCTAssertTrue(AppDelegate.wakeNeedsRebuild(screensNow: builtIn, screensBefore: builtInAndExternal, panelsOnScreen: 2))
        XCTAssertTrue(AppDelegate.displaysChanged(now: builtIn, before: builtInAndExternal))
        XCTAssertFalse(AppDelegate.displaysChanged(now: builtIn, before: builtIn))
    }

    func testAPanelGoneFromItsScreenRebuildsEvenWithTheDisplaysUnchanged() {
        // The case nothing else catches: the same display, back at the same size, with the
        // panel ordered out from under it. As far as the app knew it was still there.
        XCTAssertTrue(AppDelegate.wakeNeedsRebuild(screensNow: builtIn, screensBefore: builtIn, panelsOnScreen: 0))
        XCTAssertTrue(AppDelegate.wakeNeedsRebuild(screensNow: builtInAndExternal, screensBefore: builtInAndExternal, panelsOnScreen: 1),
                      "one of two is one short")
    }

    func testNoDisplaysAtAllIsADisplayNotBackYet() {
        // Tearing the panels down for a screen that is still waking would cost a flicker on
        // every wake; the screen-parameters notification that follows judges that case.
        XCTAssertFalse(AppDelegate.wakeNeedsRebuild(screensNow: [], screensBefore: builtIn, panelsOnScreen: 0))
        XCTAssertFalse(AppDelegate.wakeNeedsRebuild(screensNow: [], screensBefore: [], panelsOnScreen: 0))
    }
}
