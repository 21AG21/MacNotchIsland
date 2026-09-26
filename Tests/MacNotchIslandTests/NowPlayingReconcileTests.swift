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

    // MARK: - The tick, only while it has work

    func testTheTickSleepsWhileTheHelperAnswers() {
        // The Mac nearly every copy runs on: the helper answering, whether or not anything is
        // playing. The tick used to fire every second there regardless.
        XCTAssertFalse(NowPlayingService.needsTick(adapterAnswering: true, mediaRemoteAnswering: false, activeBackend: .adapter))
        XCTAssertFalse(NowPlayingService.needsTick(adapterAnswering: true, mediaRemoteAnswering: true, activeBackend: .inactive),
                       "nothing playing, and both saying so")
        XCTAssertFalse(NowPlayingService.needsTick(adapterAnswering: false, mediaRemoteAnswering: true, activeBackend: .inactive),
                       "MediaRemote holding AppleScript back does as the helper does")
    }

    func testTheTickRunsWhileAppleScriptIsTheOneToAsk() {
        XCTAssertTrue(NowPlayingService.needsTick(adapterAnswering: false, mediaRemoteAnswering: false, activeBackend: .inactive))
        XCTAssertTrue(NowPlayingService.needsTick(adapterAnswering: false, mediaRemoteAnswering: false, activeBackend: .appleScript))
        XCTAssertTrue(NowPlayingService.needsTick(adapterAnswering: false, mediaRemoteAnswering: false, activeBackend: .adapter),
                      "a helper gone quiet with its track still up is AppleScript's to take over")
    }

    func testTheTickRunsWhileMediaRemoteShowsTheTrack() {
        // MediaRemote answers questions and never reports in, so its clock drifts after a
        // seek made elsewhere unless it is asked again now and then.
        XCTAssertTrue(NowPlayingService.needsTick(adapterAnswering: false, mediaRemoteAnswering: true, activeBackend: .mediaRemote))
    }

    func testAnIdleTickIsLookedAtAgainOnceTheLastAnswerRunsOut() {
        let helperUntil = t0.addingTimeInterval(9)
        XCTAssertEqual(NowPlayingService.recheckDate(adapterAnsweringUntil: helperUntil, mediaRemoteAnswering: false, now: t0),
                       helperUntil.addingTimeInterval(NowPlayingService.recheckMargin),
                       "the helper's moment is known to the second")
        XCTAssertEqual(NowPlayingService.recheckDate(adapterAnsweringUntil: helperUntil, mediaRemoteAnswering: true, now: t0),
                       t0.addingTimeInterval(MediaRemoteBackend.staleAfter + NowPlayingService.recheckMargin),
                       "both must have run out before AppleScript is wanted, so the later of the two")
        XCTAssertEqual(NowPlayingService.recheckDate(adapterAnsweringUntil: nil, mediaRemoteAnswering: true, now: t0),
                       t0.addingTimeInterval(MediaRemoteBackend.staleAfter + NowPlayingService.recheckMargin),
                       "MediaRemote's moment is not known, and its whole window is the latest it can be")
        XCTAssertNil(NowPlayingService.recheckDate(adapterAnsweringUntil: nil, mediaRemoteAnswering: false, now: t0),
                     "with nothing answering the tick is on, and there is nothing to look out for")
    }

    func testTheHelpersDeadlineIsTheLastMomentItCountsAsAnswering() {
        // The one-shot is set by `answeringUntil` and the gate is read from `isOverdue`; the
        // two have to agree about the moment, or the look finds nothing changed and the
        // fallback waits for the next one.
        let lastMessage = t0.addingTimeInterval(-4)
        for wokeAt in [nil, t0.addingTimeInterval(-20), t0.addingTimeInterval(-1)] as [Date?] {
            guard let until = AdapterBackend.answeringUntil(lastMessage: lastMessage, wokeAt: wokeAt, within: 12) else {
                return XCTFail("a helper that has spoken has a deadline")
            }
            XCTAssertFalse(AdapterBackend.isOverdue(lastMessage: lastMessage, wokeAt: wokeAt, now: until, within: 12))
            XCTAssertTrue(AdapterBackend.isOverdue(lastMessage: lastMessage, wokeAt: wokeAt,
                                                   now: until.addingTimeInterval(NowPlayingService.recheckMargin), within: 12))
        }
        XCTAssertEqual(AdapterBackend.answeringUntil(lastMessage: lastMessage, wokeAt: t0.addingTimeInterval(-1), within: 12),
                       t0.addingTimeInterval(11), "a wake starts the window again")
        XCTAssertNil(AdapterBackend.answeringUntil(lastMessage: nil, wokeAt: t0, within: 12),
                     "a helper never heard from is not answering, wake or none")
    }

    func testTheWatchdogLooksTwiceAWindowAndNeverSoLateItThinksItSlept() {
        XCTAssertEqual(AdapterBackend.watchdogInterval, AdapterBackend.silence / 2)
        // A look that comes later than a whole window after the last is read as a sleep, and a
        // sleep forgives the helper its silence: the latest a look may come must be inside it.
        XCTAssertLessThan(AdapterBackend.watchdogInterval + AdapterBackend.watchdogTolerance, AdapterBackend.silence)
        let now = t0
        XCTAssertFalse(AdapterBackend.missedItsLooks(lastCheck: now.addingTimeInterval(-(AdapterBackend.watchdogInterval + AdapterBackend.watchdogTolerance)),
                                                     now: now, window: AdapterBackend.silence))
    }

    // MARK: - Keep paused music for

    func testAPausedTrackIsDueWhenItsTimeIsUp() {
        let paused = t0
        XCTAssertEqual(NowPlayingService.pausedTrackDue(pausedSince: paused, playing: false, keepMinutes: 5),
                       paused.addingTimeInterval(300))
        XCTAssertNil(NowPlayingService.pausedTrackDue(pausedSince: paused, playing: true, keepMinutes: 5),
                     "a track playing again, before its report has cleared the pause, is not due")
        XCTAssertNil(NowPlayingService.pausedTrackDue(pausedSince: nil, playing: false, keepMinutes: 5),
                     "nor is one not known to have paused: the button's own flip is not the player's word")
    }

    func testNotAtAllIsAMomentAfterThePauseRatherThanOnIt() {
        // "Not at all" cleared on the tick after the pause, which was up to a second later; a
        // look set for the pause itself would clear the card in the same turn it paused.
        XCTAssertEqual(NowPlayingService.pausedTrackDue(pausedSince: t0, playing: false, keepMinutes: 0),
                       t0.addingTimeInterval(NowPlayingService.pausedGrace))
        XCTAssertEqual(NowPlayingService.pausedTrackDue(pausedSince: t0, playing: false, keepMinutes: -3),
                       t0.addingTimeInterval(NowPlayingService.pausedGrace))
        XCTAssertEqual(NowPlayingService.pausedTrackDue(pausedSince: t0, playing: false, keepMinutes: .nan),
                       t0.addingTimeInterval(NowPlayingService.pausedGrace), "a setting that is not a number is no time")
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

    // MARK: - "Nothing is playing", from whoever says it

    /// A card put up by a helper that was then killed or restarted, or by a fallback the helper
    /// then took over from, used to stay for good, "playing", after the music had stopped.
    func testNothingFromTheCardsOwnBackendOrABetterOneEndsIt() {
        XCTAssertTrue(NowPlayingService.nothingEndsCard(from: .adapter, answering: true, active: .adapter, activeAnswering: true))
        XCTAssertTrue(NowPlayingService.nothingEndsCard(from: .adapter, answering: true, active: .inactive, activeAnswering: false))
        XCTAssertTrue(NowPlayingService.nothingEndsCard(from: .adapter, answering: true, active: .appleScript, activeAnswering: true),
                      "a helper back from a restart, over the fallback's card")
        XCTAssertTrue(NowPlayingService.nothingEndsCard(from: .adapter, answering: true, active: .mediaRemote, activeAnswering: true))
    }

    func testNothingEndsACardWhoseOwnBackendHasGoneQuiet() {
        XCTAssertTrue(NowPlayingService.nothingEndsCard(from: .appleScript, answering: true, active: .adapter, activeAnswering: false),
                      "the helper was killed with its track up: the fallback's word is the one there is")
        XCTAssertTrue(NowPlayingService.nothingEndsCard(from: .mediaRemote, answering: true, active: .adapter, activeAnswering: false))
    }

    func testNothingFromBelowDoesNotEndALiveCardAbove() {
        XCTAssertFalse(NowPlayingService.nothingEndsCard(from: .mediaRemote, answering: true, active: .adapter, activeAnswering: true))
        XCTAssertFalse(NowPlayingService.nothingEndsCard(from: .appleScript, answering: true, active: .mediaRemote, activeAnswering: true))
        XCTAssertFalse(NowPlayingService.nothingEndsCard(from: .adapter, answering: false, active: .mediaRemote, activeAnswering: true),
                       "a helper that has died says nothing about MediaRemote's card")
    }

    /// Up to macOS 15.3, a MediaRemote wedged after a wake answers "nothing" with Music playing.
    /// Counted because it was heard, it ended AppleScript's card; now its "nothing" counts over
    /// a card from below it only while it has had a track to show, which is what `handle`
    /// passes as answering.
    func testMediaRemotesNothingWithNoTrackLatelyLeavesTheFallbacksCard() {
        XCTAssertFalse(NowPlayingService.nothingEndsCard(from: .mediaRemote, answering: false, active: .appleScript, activeAnswering: true),
                       "heard, but with no track to show lately")
        XCTAssertTrue(NowPlayingService.nothingEndsCard(from: .mediaRemote, answering: true, active: .appleScript, activeAnswering: true),
                      "one that has just shown a track is believed")
        XCTAssertTrue(NowPlayingService.nothingEndsCard(from: .mediaRemote, answering: false, active: .mediaRemote, activeAnswering: true),
                      "its own card, as always")
        XCTAssertTrue(NowPlayingService.nothingEndsCard(from: .mediaRemote, answering: false, active: .adapter, activeAnswering: false),
                      "and a helper's card the helper has stopped answering for")
    }

    // MARK: - Covers the helper has sent

    func testACoverSeenOnceIsStillThereAfterAReportWithout() {
        var covers = AdapterBackend.CoverCache()
        let cover = NSImage(size: NSSize(width: 10, height: 10))
        covers.remember(cover, accent: .systemPink, for: "x")
        // A report with no cover (an advert, the gap between tracks) remembers nothing and forgets
        // nothing; the next track with the same cover comes as its hash alone.
        XCTAssertTrue(covers.cover(for: "x")?.image === cover)
        XCTAssertEqual(covers.cover(for: "x")?.accent, .systemPink)
        XCTAssertNil(covers.cover(for: "y"))
    }

    func testTheCoverCacheKeepsOnlyTheLatestFew() {
        var covers = AdapterBackend.CoverCache()
        let image = NSImage(size: NSSize(width: 1, height: 1))
        for n in 0...AdapterBackend.CoverCache.limit { covers.remember(image, accent: .white, for: "\(n)") }
        XCTAssertNil(covers.cover(for: "0"), "the oldest goes")
        XCTAssertNotNil(covers.cover(for: "1"))
        XCTAssertEqual(covers.order.count, AdapterBackend.CoverCache.limit)
        covers.remember(image, accent: .white, for: "1")
        XCTAssertEqual(covers.order.last, "1", "seen again, it is the newest")
        XCTAssertEqual(covers.order.count, AdapterBackend.CoverCache.limit)
    }

    // MARK: - A press belongs to its track

    /// A seek near the end, or a pause as the track ended, was read into the next track's
    /// second report, which came inside the window.
    func testAPressIsHeldAgainstItsOwnTrackOnly() {
        let ending = info("Song", playing: true, elapsed: 199, at: t0)
        let pending = NowPlayingService.Optimistic(isPlaying: nil, elapsed: 199, at: t0, until: t0 + 1.2,
                                                   track: NowPlayingService.trackKey(ending))
        let first = info("Next", playing: true, elapsed: 0, at: t0 + 0.4)
        XCTAssertFalse(NowPlayingService.keepsOptimistic(pending, after: first, now: t0 + 0.4),
                       "the first report of another track ends it")
        let second = info("Next", playing: true, elapsed: 0.4, at: t0 + 0.8)
        let result = NowPlayingService.reconcile(incoming: second, current: first, optimistic: pending, now: t0 + 0.8)
        XCTAssertEqual(result.position(at: t0 + 0.8), 0.4, accuracy: 0.05, "the next track keeps its own clock")

        let stale = info("Song", playing: true, elapsed: 30, at: t0)
        XCTAssertTrue(NowPlayingService.keepsOptimistic(pending, after: stale, now: t0 + 0.2), "its own track, still behind")
        XCTAssertEqual(NowPlayingService.reconcile(incoming: stale, current: ending, optimistic: pending, now: t0 + 0.2)
                        .position(at: t0 + 0.2), 199.2, accuracy: 0.05)
        XCTAssertFalse(NowPlayingService.keepsOptimistic(pending, after: stale, now: t0 + 2), "and not past its window")
    }

    // MARK: - A report that does not say where the playhead is

    func testAStreamThatSaysNothingOfItsPlayheadKeepsItsClock() {
        let current = info("Radio", playing: true, elapsed: 90, at: t0)
        var bare = info("Radio", playing: true, elapsed: 0, at: t0 + 5)
        bare.reportsPosition = false
        let kept = NowPlayingService.reconcile(incoming: bare, current: current, optimistic: nil, now: t0 + 5)
        XCTAssertEqual(kept.position(at: t0 + 5), 95, accuracy: 0.01, "on from where it was, not 0:00 again")

        var paused = bare
        paused.isPlaying = false
        let stopped = NowPlayingService.carryingPosition(into: paused, from: current, now: t0 + 5)
        XCTAssertEqual(stopped.position(at: t0 + 60), 95, accuracy: 0.01, "paused where the playhead was")

        var other = bare
        other.title = "Another station"
        XCTAssertEqual(NowPlayingService.carryingPosition(into: other, from: current, now: t0 + 5).elapsed, 0,
                       "another track starts from its own nothing")
        let reported = info("Radio", playing: true, elapsed: 12, at: t0 + 5)
        XCTAssertEqual(NowPlayingService.carryingPosition(into: reported, from: current, now: t0 + 5).elapsed, 12,
                       "a report that says where it is, is believed")
    }

    // MARK: - Where a press goes, and whether it went

    func testWithNoCardAPressGoesToTheHelperThatIsAnswering() {
        XCTAssertEqual(NowPlayingService.transportBackend(active: .inactive, adapterAnswering: true), .adapter)
        XCTAssertEqual(NowPlayingService.transportBackend(active: .inactive, adapterAnswering: false), .inactive,
                       "MediaRemote in the app, as before, with nobody else to ask")
        XCTAssertEqual(NowPlayingService.transportBackend(active: .appleScript, adapterAnswering: true), .appleScript,
                       "the backend showing the track keeps its presses")
        XCTAssertEqual(NowPlayingService.transportBackend(active: .mediaRemote, adapterAnswering: false), .mediaRemote)
    }

    /// The heart was lit before the press was sent, whatever came of it.
    func testTheHeartLightsOnlyForAPressThatWentThrough() {
        let pressed = NowPlayingService.trackKey(info(playing: true))
        XCTAssertEqual(NowPlayingService.likedKey(afterFavouriting: pressed, succeeded: true, now: nil), pressed)
        XCTAssertNil(NowPlayingService.likedKey(afterFavouriting: pressed, succeeded: false, now: nil))
        XCTAssertEqual(NowPlayingService.likedKey(afterFavouriting: pressed, succeeded: false, now: "another|track"), "another|track",
                       "a failed press leaves the heart as it was")
    }

    func testMediaRemotesOwnWordOnPlayingDecides() {
        XCTAssertTrue(NowPlayingInfo.isPlaying(rate: 1, flag: nil), "without it, the rate")
        XCTAssertFalse(NowPlayingInfo.isPlaying(rate: 0, flag: nil))
        XCTAssertFalse(NowPlayingInfo.isPlaying(rate: nil, flag: nil))
        XCTAssertFalse(NowPlayingInfo.isPlaying(rate: .nan, flag: nil))
        XCTAssertFalse(NowPlayingInfo.isPlaying(rate: 1, flag: false), "a rate left standing across a pause")
        XCTAssertTrue(NowPlayingInfo.isPlaying(rate: 0, flag: true))
    }

    // MARK: - AppleScript

    private func scripted(_ bundle: String, playing: Bool) -> NowPlayingInfo {
        NowPlayingInfo(title: bundle, artist: "Band", album: "", duration: 200, elapsed: 0, timestamp: t0,
                       isPlaying: playing, bundleID: bundle, artwork: nil, artworkID: 0, accent: .white)
    }

    /// With both players open and neither playing, Spotify was always the one shown, so pausing
    /// Music from the card flipped it to Spotify's old track.
    func testWithNothingPlayingTheCardKeepsItsPlayer() {
        let spotify = scripted(AppleScriptBackend.spotifyID, playing: false)
        let music = scripted(AppleScriptBackend.musicID, playing: false)
        XCTAssertEqual(AppleScriptBackend.choose([spotify, music], preferring: AppleScriptBackend.musicID)?.bundleID,
                       AppleScriptBackend.musicID)
        XCTAssertEqual(AppleScriptBackend.choose([spotify, music], preferring: nil)?.bundleID, AppleScriptBackend.spotifyID)
        let playing = scripted(AppleScriptBackend.spotifyID, playing: true)
        XCTAssertEqual(AppleScriptBackend.choose([playing, music], preferring: AppleScriptBackend.musicID)?.bundleID,
                       AppleScriptBackend.spotifyID, "one that plays wins")
        let both = scripted(AppleScriptBackend.musicID, playing: true)
        XCTAssertEqual(AppleScriptBackend.choose([playing, both], preferring: AppleScriptBackend.musicID)?.bundleID,
                       AppleScriptBackend.musicID, "of two that play, the card's")
        XCTAssertNil(AppleScriptBackend.choose([], preferring: AppleScriptBackend.musicID))
    }

    private func press(_ kind: AppleScriptBackend.Press.Kind, _ source: String = "", at seconds: TimeInterval = 0,
                       player: String = AppleScriptBackend.musicID) -> AppleScriptBackend.Press {
        AppleScriptBackend.Press(kind: kind, player: player, source: source, at: t0 + seconds)
    }

    /// Presses queued without limit behind a player that was not answering, and ran back to
    /// back when it recovered: every play/pause pressed meanwhile, late.
    func testPressesMadeWhileAPlayerIsStuckAreFolded() {
        var waiting: [AppleScriptBackend.Press] = []
        waiting = AppleScriptBackend.coalesced(waiting, adding: press(.toggle))
        waiting = AppleScriptBackend.coalesced(waiting, adding: press(.toggle))
        XCTAssertTrue(waiting.isEmpty, "two play/pauses are none")
        waiting = AppleScriptBackend.coalesced(waiting, adding: press(.toggle))
        waiting = AppleScriptBackend.coalesced(waiting, adding: press(.next))
        waiting = AppleScriptBackend.coalesced(waiting, adding: press(.next))
        waiting = AppleScriptBackend.coalesced(waiting, adding: press(.toggle))
        XCTAssertEqual(waiting.map(\.kind), [.toggle, .next, .toggle], "a second next is the same press; a toggle after it is not undone")
        waiting = AppleScriptBackend.coalesced(waiting, adding: press(.seek, "30"))
        waiting = AppleScriptBackend.coalesced(waiting, adding: press(.seek, "90"))
        XCTAssertEqual(waiting.filter { $0.kind == .seek }.map(\.source), ["90"], "only the last seek")
        let hearts = AppleScriptBackend.coalesced(AppleScriptBackend.coalesced([], adding: press(.like)), adding: press(.like))
        XCTAssertEqual(hearts.count, 2, "a press someone waits on an answer for is never folded away")
        let twoPlayers = AppleScriptBackend.coalesced([press(.toggle, player: AppleScriptBackend.spotifyID)], adding: press(.toggle))
        XCTAssertEqual(twoPlayers.count, 2, "a toggle in each player is two toggles")
    }

    func testAPressThatWaitedTooLongIsNotSent() {
        XCTAssertTrue(AppleScriptBackend.stillWanted(press(.toggle), now: t0 + AppleScriptBackend.pressPatience))
        XCTAssertFalse(AppleScriptBackend.stillWanted(press(.toggle), now: t0 + AppleScriptBackend.pressPatience + 1))
        XCTAssertFalse(AppleScriptBackend.stillWanted(press(.next), now: t0 + AppleScriptBackend.pressPatience + 1))
        XCTAssertFalse(AppleScriptBackend.stillWanted(press(.like), now: t0 + AppleScriptBackend.pressPatience + 1))
    }

    /// The sleep timer's pause, queued behind a press that was slow to come back, was dropped
    /// with the card showing paused and the music playing on. A pause sent late cannot start
    /// anything.
    func testAPauseIsNeverTooLate() {
        XCTAssertTrue(AppleScriptBackend.stillWanted(press(.pause), now: t0 + AppleScriptBackend.pressPatience + 1))
        XCTAssertTrue(AppleScriptBackend.stillWanted(press(.pause), now: t0 + 120))
        XCTAssertTrue(AppleScriptBackend.stillWanted(press(.pause, player: AppleScriptBackend.spotifyID), now: t0 + 120),
                      "in either player")
    }

    func testEveryScriptHasATimeout() {
        let timed = ScriptQueue.timed("tell application \"Music\" to pause", seconds: 5)
        XCTAssertTrue(timed.hasPrefix("with timeout of 5 seconds\n"))
        XCTAssertTrue(timed.hasSuffix("\nend timeout"))
        XCTAssertTrue(ScriptQueue.timed("x", seconds: 0).hasPrefix("with timeout of 1 seconds"), "never none at all")
    }

    /// A cover that came in late was dropped with the track marked done, and that track never
    /// had one.
    func testASpotifyCoverThatDidNotArriveIsAskedForAgain() {
        XCTAssertTrue(AppleScriptBackend.fetchesCover(hasCover: false, attempts: 0))
        XCTAssertTrue(AppleScriptBackend.fetchesCover(hasCover: false, attempts: 1), "the next poll tries again")
        XCTAssertFalse(AppleScriptBackend.fetchesCover(hasCover: false, attempts: AppleScriptBackend.coverAttemptLimit))
        XCTAssertFalse(AppleScriptBackend.fetchesCover(hasCover: true, attempts: 0))
    }

    /// A player open with nothing playing was scripted every two seconds for as long as it
    /// stayed open.
    func testAppleScriptAsksLessOftenWhileItKeepsFindingNothing() {
        XCTAssertEqual(NowPlayingService.appleScriptPollEvery(onBattery: false, idleAnswers: 0, nobodyLooking: false,
                                                              mediaRemoteSaysNothing: false), 2)
        XCTAssertEqual(NowPlayingService.appleScriptPollEvery(onBattery: true, idleAnswers: 0, nobodyLooking: false,
                                                              mediaRemoteSaysNothing: false), 4)
        XCTAssertEqual(NowPlayingService.appleScriptPollEvery(onBattery: false, idleAnswers: 5, nobodyLooking: false,
                                                              mediaRemoteSaysNothing: false), 6)
        XCTAssertEqual(NowPlayingService.appleScriptPollEvery(onBattery: false, idleAnswers: 30, nobodyLooking: false,
                                                              mediaRemoteSaysNothing: false), 10)
        XCTAssertEqual(NowPlayingService.appleScriptPollEvery(onBattery: true, idleAnswers: 0, nobodyLooking: true,
                                                              mediaRemoteSaysNothing: false), 20,
                       "nobody at the Mac")
        XCTAssertEqual(NowPlayingService.idleAnswers(after: .answered(nil), count: 3), 4)
        XCTAssertEqual(NowPlayingService.idleAnswers(after: .answered(info(playing: false)), count: 3), 4,
                       "a paused track is nothing new")
        XCTAssertEqual(NowPlayingService.idleAnswers(after: .answered(info(playing: true)), count: 30), 0,
                       "one that plays starts again")
    }

    /// A poll with neither player open counted as idle, so three minutes with both closed and a
    /// track started in a newly opened Music came up to ten seconds late.
    func testAPollWithNoPlayerOpenStartsTheCountAgain() {
        XCTAssertEqual(NowPlayingService.idleAnswers(after: .noPlayer, count: 30), 0)
        XCTAssertEqual(NowPlayingService.idleAnswers(after: .noPlayer, count: 0), 0)
        XCTAssertNil(AppleScriptBackend.PollResult.noPlayer.report, "and the island is told nothing is playing")
        XCTAssertNil(AppleScriptBackend.PollResult.answered(nil).report)
        XCTAssertEqual(AppleScriptBackend.PollResult.answered(info(playing: true)).report, info(playing: true))
    }

    /// Up to macOS 15.3, MediaRemote's "nothing" held AppleScript back altogether, and a
    /// MediaRemote wedged after a wake that said it with Music playing kept the card dark for
    /// good. Now AppleScript still looks, at its slowest.
    func testMediaRemoteSayingNothingSlowsAppleScriptRatherThanStoppingIt() {
        XCTAssertEqual(NowPlayingService.appleScriptPollEvery(onBattery: false, idleAnswers: 0, nobodyLooking: false,
                                                              mediaRemoteSaysNothing: true), 10)
        XCTAssertEqual(NowPlayingService.appleScriptPollEvery(onBattery: true, idleAnswers: 0, nobodyLooking: false,
                                                              mediaRemoteSaysNothing: true), 20, "on battery")
        XCTAssertEqual(NowPlayingService.appleScriptPollEvery(onBattery: false, idleAnswers: 30, nobodyLooking: true,
                                                              mediaRemoteSaysNothing: true), 10, "never slower than the slowest")
    }

    func testMediaRemoteSaysNothingOnlyWhereItAnswersThisApp() {
        XCTAssertTrue(NowPlayingService.mediaRemoteSaysNothing(answersThisApp: true, answering: true, deliveringTrack: false))
        XCTAssertFalse(NowPlayingService.mediaRemoteSaysNothing(answersThisApp: true, answering: true, deliveringTrack: true),
                       "a track lately: it holds AppleScript back, as before")
        XCTAssertFalse(NowPlayingService.mediaRemoteSaysNothing(answersThisApp: true, answering: false, deliveringTrack: false),
                       "not answering is not saying anything")
        XCTAssertFalse(NowPlayingService.mediaRemoteSaysNothing(answersThisApp: false, answering: true, deliveringTrack: false),
                       "from 15.4 its empty answers are not this, and change nothing")
    }

    // MARK: - Covers, decoded small and off the main thread

    /// A picture of one colour, `width` by `height` pixels, as a player would hand its bytes over.
    private func png(width: Int, height: Int, color: NSColor) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func assertClose(_ a: NSColor, _ b: NSColor?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let x = a.usingColorSpace(.deviceRGB), let y = b?.usingColorSpace(.deviceRGB) else {
            return XCTFail("no colour to compare: \(message)", file: file, line: line)
        }
        XCTAssertEqual(x.redComponent, y.redComponent, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(x.greenComponent, y.greenComponent, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(x.blueComponent, y.blueComponent, accuracy: 0.02, message, file: file, line: line)
    }

    /// A player's cover is many hundreds of pixels, often more, for a picture drawn at 60 pt at
    /// most. It is kept no larger than the island draws one, the same shape, and with the
    /// accent the whole picture gives.
    func testACoverIsDecodedNoLargerThanTheIslandDrawsIt() throws {
        let bytes = try png(width: 1200, height: 800, color: .systemPink)
        let cover = try XCTUnwrap(NSImage.cover(from: bytes))
        let kept = try XCTUnwrap(cover.image.representations.first)
        XCTAssertEqual(kept.pixelsWide, NSImage.coverPixels, "the long side at the most the island draws")
        XCTAssertEqual(kept.pixelsHigh, NSImage.coverPixels * 2 / 3, "and the short side in proportion")
        XCTAssertEqual(cover.image.size, NSSize(width: kept.pixelsWide, height: kept.pixelsHigh),
                       "a point to a pixel, as the bytes had it")
        assertClose(cover.accent, NSImage(data: bytes)?.dominantColor(), "the accent the whole picture gives")
        XCTAssertGreaterThanOrEqual(NSImage.coverPixels, 120, "the 60 pt cover on a Retina display is not made blurry")
    }

    func testASmallCoverIsNotMadeLarger() throws {
        let cover = try XCTUnwrap(NSImage.cover(from: png(width: 100, height: 80, color: .systemTeal)))
        let kept = try XCTUnwrap(cover.image.representations.first)
        XCTAssertEqual(kept.pixelsWide, 100)
        XCTAssertEqual(kept.pixelsHigh, 80)
    }

    func testBytesThatAreNotAPictureAreNoCover() {
        XCTAssertNil(NSImage.cover(from: Data("not a picture".utf8)))
        XCTAssertNil(NSImage.cover(from: Data()))
    }

    /// MediaRemote hands over a cover's bytes with every report about its track; only new ones
    /// are decoded, and a report without any has no cover.
    func testOnlyNewCoverBytesAreDecoded() {
        XCTAssertEqual(MediaRemoteBackend.coverStep(hash: 42, last: 0), .decode, "a first cover")
        XCTAssertEqual(MediaRemoteBackend.coverStep(hash: 42, last: 42), .keep, "the same bytes again: the same cover")
        XCTAssertEqual(MediaRemoteBackend.coverStep(hash: 43, last: 42), .decode, "the next track's")
        XCTAssertEqual(MediaRemoteBackend.coverStep(hash: nil, last: 42), .clear, "no bytes, no cover")
        XCTAssertEqual(MediaRemoteBackend.coverStep(hash: nil, last: 0), .clear)
    }

    /// A new cover is decoded off the main thread, and the report that brought it waits for it.
    /// A report behind it must not go out first: the card would take the older report last.
    func testAReportBehindANewCoverWaitsForIt() throws {
        let backend = MediaRemoteBackend()
        let bytes = try png(width: 1200, height: 1200, color: .systemIndigo)
        var order: [String] = []
        let done = expectation(description: "both reports out")
        backend.inOrder(decoding: bytes) { decoded, current in
            XCTAssertNotNil(decoded, "the cover comes with its report")
            XCTAssertTrue(current)
            order.append("cover")
        }
        backend.inOrder(decoding: nil) { decoded, current in
            XCTAssertNil(decoded)
            XCTAssertTrue(current)
            order.append("next")
            done.fulfill()
        }
        XCTAssertEqual(order, [], "neither goes out on the main thread's turn that took them in")
        // Held until they land: a report whose backend has gone is dropped, not passed on.
        withExtendedLifetime(backend) { wait(for: [done], timeout: 10) }
        XCTAssertEqual(order, ["cover", "next"], "in the order they came")

        var now: [String] = []
        backend.inOrder(decoding: nil) { _, current in
            XCTAssertTrue(current)
            now.append("at once")
        }
        XCTAssertEqual(now, ["at once"], "with nothing to decode and nothing waiting, a report goes out as it always did")
    }

    /// An answer to a question asked before the backend was switched off is not passed on,
    /// however long its cover took.
    func testAReportStillDecodingWhenSwitchedOffIsNotPassedOn() throws {
        let backend = MediaRemoteBackend()
        let bytes = try png(width: 600, height: 600, color: .systemOrange)
        let landed = expectation(description: "the report lands")
        backend.inOrder(decoding: bytes) { decoded, current in
            XCTAssertNotNil(decoded, "the cover is still taken in, for the next report to be weighed against")
            XCTAssertFalse(current, "but the report is not passed on")
            landed.fulfill()
        }
        backend.stop()
        withExtendedLifetime(backend) { wait(for: [landed], timeout: 10) }
    }

    // MARK: - The player's name

    /// Looked up once per player: the Music section asked LaunchServices and the disk for it on
    /// every pass, up to five times. The same name comes back, and a player nowhere to be found
    /// is "Now Playing", as it was.
    func testAPlayersNameIsLookedUpOnceAndIsTheSameName() throws {
        XCTAssertEqual(NowPlayingInfo.appName(bundleID: nil), "Now Playing")
        XCTAssertEqual(NowPlayingInfo.appName(bundleID: "invalid.notch-island.no-such-player"), "Now Playing")
        XCTAssertEqual(NowPlayingInfo.appName(bundleID: "invalid.notch-island.no-such-player"), "Now Playing",
                       "not found is asked again, and is still not a name")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            throw XCTSkip("LaunchServices cannot find Finder in this session")
        }
        let expected = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        XCTAssertEqual(NowPlayingInfo.appName(bundleID: "com.apple.finder"), expected, "the name Finder shows")
        XCTAssertEqual(NowPlayingInfo.appName(bundleID: "com.apple.finder"), expected, "and the same one kept")
        var report = info(playing: true)
        report.bundleID = "com.apple.finder"
        XCTAssertEqual(report.appName, expected, "which is what a report's name is")
    }
}
