import AppKit
import Combine
import XCTest
@testable import MacNotchIsland

final class ActivityCenterTests: XCTestCase {
    private var center: ActivityCenter { ActivityCenter.shared }

    override func setUp() {
        super.setUp()
        center.resetForTesting()
        let p = Preferences.shared
        p.hoverToExpand = true
        p.expandOnIdleHover = true
        p.hoverDelay = 0.01
        // Every section on, whatever an earlier test switched off: these preferences are one
        // shared object, and the ring is built from them.
        HomeSection.allCases.forEach { $0.setEnabled(true, in: p) }
    }

    /// Puts the sections back, because `onlyMusicSection` switches every one of them off and
    /// preferences are one shared object written straight through to the defaults domain.
    ///
    /// `setUp` heals it for the next test in this class, which is why nothing here ever
    /// noticed — but the damage escapes the class. The gallery runs as its own `swift test`
    /// invocation against the same domain, and a section it finds switched off is not drawn
    /// empty: it quietly resolves to the nearest one that is on, and files the picture under
    /// the wrong name.
    override func tearDown() {
        HomeSection.allCases.forEach { $0.setEnabled(true, in: Preferences.shared) }
        super.tearDown()
    }

    private func custom(_ id: String, priority: Int = 70, title: String = "X", kind: ActivityKind = .custom) -> IslandActivity {
        IslandActivity(id: id, kind: kind, content: .custom(CustomActivity(title: title)), priority: priority)
    }

    func testIdleByDefault() {
        XCTAssertEqual(center.presentation, .idle)
    }

    // MARK: - A drag over the Actions section

    func testADragOverTheIslandOpensTheShelf() {
        center.open(.home(tab: HomeSection.music.rawValue))
        center.setDragTargeted(true)
        XCTAssertEqual(center.presentation, .shelf)
        center.setDragTargeted(false)
    }

    func testADragLeavesTheSectionsWhoseTilesTakeOneAlone() {
        // Their tiles are drop targets of their own; the shelf's well would cover them.
        for section in ActivityCenter.dropTargetSections {
            center.open(.home(tab: section.rawValue))
            center.setDragTargeted(true)
            XCTAssertEqual(center.presentation, .panel(.home(tab: section.rawValue)),
                           "\(section.rawValue) takes its own drops")
            center.setDragTargeted(false)
        }
    }

    func testASlotTakingTheDragDoesNotCountAsTheDragLeaving() {
        // Every drop target inside the island takes the drag off the island's own, and the
        // island is told it has left. It has not: it is on a slot of the switcher.
        center.open(.home(tab: HomeSection.music.rawValue))
        center.setDragTargeted(true)
        center.setDragTargeted(false)
        center.holdDrag(true)
        XCTAssertEqual(center.presentation, .shelf, "the well stays under the hand that is over it")
        center.holdDrag(false)
        center.setDragTargeted(false)
    }

    func testTheShelfSectionItselfStillShowsTheWell() {
        center.open(.home(tab: HomeSection.shelf.rawValue))
        center.setDragTargeted(true)
        XCTAssertEqual(center.presentation, .shelf)
        center.setDragTargeted(false)
    }

    // MARK: - What a Focus holds back

    private func holds(_ content: ActivityContent, id: String = "x") -> Bool {
        ActivityCenter.focusHolds(IslandActivity(id: id, kind: .custom, content: content, priority: 70))
    }

    func testAFocusHoldsWhatArrivesOnItsOwn() {
        XCTAssertTrue(holds(.download(DownloadState(name: "f.zip", bytes: 10, total: 20, app: "Safari"))))
        XCTAssertTrue(holds(.bluetooth(BluetoothState(name: "AirPods", address: "a", symbol: "airpods"))))
        XCTAssertTrue(holds(.calendar(CalendarState(title: "Standup", start: Date(), end: Date(),
                                                     location: nil, joinURL: nil, tint: "blue"))))
        XCTAssertTrue(ActivityCenter.focusHolds(custom("api-build")), "a script's alert can wait")
    }

    func testAFocusNeverHoldsWhatYouJustDid() {
        XCTAssertFalse(holds(.hud(LevelHUD(kind: .volume, level: 0.4))))
        XCTAssertFalse(holds(.silent(SilentState(isSilent: true))))
        XCTAssertFalse(holds(.unlock))
        XCTAssertFalse(ActivityCenter.focusHolds(custom("screenshot-shot.png")), "you pressed the keys for it")
        XCTAssertFalse(ActivityCenter.focusHolds(custom("shelf-copied")))
    }

    func testAFocusIsNotARequestToBeAllowedToRunOut() {
        let low = BatteryState(percent: 8, isCharging: false, isPluggedIn: false, event: .low)
        XCTAssertFalse(holds(.battery(low)))
        let plugged = BatteryState(percent: 80, isCharging: true, isPluggedIn: true, event: .pluggedIn)
        XCTAssertTrue(holds(.battery(plugged)), "the charger going in can wait")
    }

    // MARK: - Whether the bare notch answers the pointer

    func testTheSwitchForHoveringAnEmptyNotchActuallyGovernsIt() {
        // It sat in Settings for some time with its reader deleted out from under it, saying
        // "resting on the notch does nothing unless this is on" while resting on the notch
        // worked either way. A switch wired to nothing is a lie told straight to the user.
        XCTAssertFalse(ActivityCenter.peeksWhenIdle(hasLiveActivity: false, idleHover: false))
        XCTAssertTrue(ActivityCenter.peeksWhenIdle(hasLiveActivity: false, idleHover: true))
    }

    func testSomethingLiveIsAlwaysWorthPeekingAtWhateverTheSwitchSays() {
        // The switch is about the *empty* notch. With a track playing or a file landing there
        // is something to see, and hovering shows it.
        XCTAssertTrue(ActivityCenter.peeksWhenIdle(hasLiveActivity: true, idleHover: false))
        XCTAssertTrue(ActivityCenter.peeksWhenIdle(hasLiveActivity: true, idleHover: true))
    }

    // MARK: - The keys the panel answers

    /// The live rule, with the keyboard held — which is the state these three are about.
    private func claimed(open: Bool, typing: Bool, enabled: Bool) -> Bool {
        HotKeyService.claim(pinnedOpen: open, holdsKeyboard: true, textFieldUp: typing,
                            listSection: false, enabled: enabled).bareKeys
    }

    func testThePanelOwnsItsKeysOnlyWhileItIsPinnedOpen() {
        // A peek follows the pointer and takes nothing from the keyboard.
        XCTAssertFalse(claimed(open: false, typing: false, enabled: true))
        XCTAssertTrue(claimed(open: true, typing: false, enabled: true))
    }

    func testNothingTheIslandClaimsSitsBetweenSomebodyAndTheirText() {
        XCTAssertFalse(claimed(open: true, typing: true, enabled: true))
    }

    func testTheKeysCanBeSwitchedOff() {
        XCTAssertFalse(claimed(open: true, typing: false, enabled: false))
    }

    func testSpaceIsQuickLookOnlyWhileTheShelfIsTheSectionOnScreen() {
        center.open(.home(tab: HomeSection.shelf.rawValue))
        XCTAssertTrue(center.isShowingShelf)
        center.open(.home(tab: HomeSection.music.rawValue))
        XCTAssertFalse(center.isShowingShelf)
        center.collapse(reason: "test")
        XCTAssertFalse(center.isShowingShelf, "nothing is open, so nothing is the shelf")
    }

    func testADigitGoesStraightToThatSlotOfTheSwitcher() {
        center.showHome()
        let ring = center.ring
        XCTAssertGreaterThan(ring.count, 2, "the ring needs a few slots for this to mean anything")
        XCTAssertTrue(center.selectSlot(2))
        XCTAssertEqual(center.currentView, ring[2])
        XCTAssertTrue(center.selectSlot(0))
        XCTAssertEqual(center.currentView, ring[0])
    }

    func testADigitPastTheEndOfTheSwitcherDoesNothing() {
        center.showHome()
        let ring = center.ring
        let before = center.currentView
        XCTAssertFalse(center.selectSlot(ring.count), "there is no slot there to land on")
        XCTAssertFalse(center.selectSlot(-1))
        XCTAssertEqual(center.currentView, before)
    }

    func testLiveActivityShowsCompact() {
        center.upsert(custom("a"))
        guard case .compact(let a, let bubble) = center.presentation else { return XCTFail("expected compact") }
        XCTAssertEqual(a.id, "a")
        XCTAssertNil(bubble)
    }

    func testSecondActivityBecomesBubbleAndPromoteSwaps() {
        center.upsert(custom("music", priority: 50))
        center.upsert(custom("timer", priority: 90))
        guard case .compact(let primary, let bubble) = center.presentation else { return XCTFail("expected compact") }
        XCTAssertEqual(primary.id, "timer")
        XCTAssertEqual(bubble?.id, "music")

        center.promote(id: "music")
        guard case .compact(let p2, let b2) = center.presentation else { return XCTFail("expected compact") }
        XCTAssertEqual(p2.id, "music")
        XCTAssertEqual(b2?.id, "timer")
    }

    func testAlertTakesOverAndClearsAfterDuration() {
        center.upsert(custom("a"))
        let alert = IslandActivity(id: "battery", kind: .battery,
                                   content: .battery(BatteryState(percent: 80, isCharging: true, isPluggedIn: true, event: .pluggedIn)),
                                   priority: 85)
        center.showAlert(alert, duration: 0.15)
        guard case .compact(let shown, _) = center.presentation else { return XCTFail("expected compact alert") }
        XCTAssertEqual(shown.id, "battery")

        let exp = expectation(description: "alert dismissed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        guard case .compact(let back, _) = center.presentation else { return XCTFail("expected live activity back") }
        XCTAssertEqual(back.id, "a")
    }

    func testExpandedAlertPresentation() {
        let alert = IslandActivity(id: "bt", kind: .bluetooth,
                                   content: .bluetooth(BluetoothState(name: "AirPods", address: "", symbol: "airpods", batteryLeft: 50)),
                                   priority: 85, presentation: .expanded)
        center.showAlert(alert, duration: 5)
        guard case .card(let shown) = center.presentation else { return XCTFail("expected a card") }
        XCTAssertEqual(shown.id, "bt")
        center.dismissAlert()
        XCTAssertEqual(center.presentation, .idle)
    }

    func testHoverExpandsPrimaryAndIdleHoverOpensHome() {
        center.upsert(custom("a"))
        center.setHovering(true)
        let exp = expectation(description: "hover applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(center.presentation, .panel(.activity(id: "a")), "the pointer opens the panel on the activity's card")
        XCTAssertFalse(center.isOpen, "under the pointer, not pinned")

        center.end(id: "a")
        guard case .panel(.home) = center.presentation else { return XCTFail("hovering with nothing live shows Home") }

        center.setHovering(false)
        let exp2 = expectation(description: "hover cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivityCenter.hoverExitGrace + 0.4) { exp2.fulfill() }
        wait(for: [exp2], timeout: 3)
        XCTAssertEqual(center.presentation, .idle)
    }

    func testDragTargetShowsShelf() {
        center.upsert(custom("a"))
        center.setDragTargeted(true)
        XCTAssertEqual(center.presentation, .shelf)
        center.setDragTargeted(false)
        // The well does not go the instant the drag appears to leave: every drop target inside
        // the island takes the drag off the island's own for as long as the pointer is over
        // it, so leaving is given a moment to be a drag that has moved onto a tile.
        XCTAssertEqual(center.presentation, .shelf, "still the well, for a moment")
        let done = expectation(description: "the drag has really gone")
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivityCenter.dragExitGrace + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 3)
        guard case .compact = center.presentation else { return XCTFail("expected compact after drag ends") }
    }

    func testUpsertKeepsStartDateAndEndRemoves() {
        center.upsert(custom("a", title: "one"))
        let started = center.activity(id: "a")?.startedAt
        center.upsert(custom("a", title: "two"))
        XCTAssertEqual(center.activity(id: "a")?.startedAt, started)
        if case .custom(let c)? = center.activity(id: "a")?.content { XCTAssertEqual(c.title, "two") } else { XCTFail() }
        XCTAssertEqual(center.activities.count, 1)
        center.end(id: "a")
        XCTAssertEqual(center.presentation, .idle)
    }

    func testForcedExpansion() {
        center.upsert(custom("timer", priority: 90))
        center.forceExpanded(id: "timer", for: 5)
        guard case .card(let a) = center.presentation else { return XCTFail("expected a forced card") }
        XCTAssertEqual(a.id, "timer")
        center.collapse()
        guard case .compact = center.presentation else { return XCTFail("expected compact after collapse") }
    }

    func testPrivacyIndicatorsFollowPreference() {
        Preferences.shared.privacyIndicatorsEnabled = true
        center.micInUse = true
        XCTAssertTrue(center.privacyIndicatorsVisible)
        Preferences.shared.privacyIndicatorsEnabled = false
        XCTAssertFalse(center.privacyIndicatorsVisible)
        Preferences.shared.privacyIndicatorsEnabled = true
    }

    // MARK: - Ordering

    func testNewestKindTakesTheIslandAndUrgentAlwaysWins() {
        var timer = custom("timer", priority: 90, kind: .timer)
        timer.startedAt = Date(timeIntervalSinceNow: -60)
        var music = custom("music", priority: 50, kind: .nowPlaying)
        music.startedAt = Date()
        let ordered = ActivityCenter.ordered([timer, music], pinnedID: nil)
        XCTAssertEqual(ordered.map(\.id), ["music", "timer"], "the activity that started last owns the island")

        var call = custom("call", priority: 100, kind: .call)
        call.startedAt = Date(timeIntervalSinceNow: -600)
        XCTAssertEqual(ActivityCenter.ordered([timer, music, call], pinnedID: nil).first?.id, "call")
        XCTAssertEqual(ActivityCenter.ordered([timer, music], pinnedID: "timer").first?.id, "timer")

        var shelf = IslandActivity(id: "shelf", kind: .shelf, content: .shelf(ShelfState(count: 2)), priority: 30)
        shelf.startedAt = Date(timeIntervalSinceNow: 10)
        XCTAssertEqual(ActivityCenter.ordered([music, shelf], pinnedID: nil).map(\.id), ["music", "shelf"],
                       "the shelf is ambient: newest or not, it waits in the bubble while something plays")
        XCTAssertEqual(ActivityCenter.ordered([shelf], pinnedID: nil).first?.id, "shelf")
    }

    func testActivitiesOfOneKindKeepTheirOwnPriorityOrder() {
        var soon = IslandActivity(id: "timer", kind: .timer,
                                  content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 91)
        soon.startedAt = Date(timeIntervalSinceNow: -120)
        var later = IslandActivity(id: "timer-2", kind: .timer,
                                   content: .timer(TimerState(label: "Roast", total: 3600, endDate: Date(timeIntervalSinceNow: 3600))), priority: 90)
        later.startedAt = Date()
        var music = custom("music", priority: 50, kind: .nowPlaying)
        music.startedAt = Date(timeIntervalSinceNow: -30)
        let ordered = ActivityCenter.ordered([music, later, soon], pinnedID: nil)
        XCTAssertEqual(ordered.map(\.id), ["timer", "timer-2", "music"],
                       "a newer timer keeps the timers first, but the soonest one leads them")
    }

    // MARK: - Clicks and keyboard

    func testClickOpensAndOnlyAnOutsideCloseCollapses() {
        Preferences.shared.hoverToExpand = false
        Preferences.shared.expandOnIdleHover = false
        center.upsert(IslandActivity(id: "timer", kind: .timer,
                                     content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 90))
        guard case .compact = center.presentation else { return XCTFail("compact at rest") }
        center.tap()
        XCTAssertEqual(center.presentation, .panel(.activity(id: "timer")), "a click opens the panel on the activity")
        XCTAssertTrue(center.isOpen)
        center.tap()
        guard case .panel = center.presentation else { return XCTFail("a click on the open panel leaves it open") }
        XCTAssertTrue(center.isOpen)
        center.collapse(reason: "test")
        guard case .compact = center.presentation else { return XCTFail("closing from outside collapses it") }
        XCTAssertFalse(center.isOpen)

        center.end(id: "timer")
        center.tap()
        guard case .panel(.home) = center.presentation else { return XCTFail("clicking the empty island opens Home") }
        center.collapse()
        XCTAssertEqual(center.presentation, .idle)
    }

    func testEndingAnOpenActivityClosesIt() {
        center.upsert(IslandActivity(id: "timer", kind: .timer,
                                     content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 90))
        center.open(.activity(id: "timer"))
        center.end(id: "timer")
        XCTAssertFalse(center.isOpen)
        XCTAssertEqual(center.presentation, .idle)
    }

    // MARK: - The order of the sections

    func testTheGridIsTheFrontDoorAndCannotBeSwitchedOff() {
        let prefs = Preferences.shared
        XCTAssertEqual(HomeSection.allCases.first, .home, "Home is the first slot on the switcher")
        XCTAssertEqual(HomeSection.fallback, .home)
        HomeSection.home.setEnabled(false, in: prefs)
        XCTAssertTrue(HomeSection.home.isEnabled(prefs), "there is no switch for it")
        XCTAssertFalse(HomeSection.tiles(prefs).contains(.home), "and it is not a tile on itself")
        // Nor is Now Playing: it has the wide tile at the head of the grid, and listing it
        // again beside its own tile put it there twice.
        XCTAssertFalse(HomeSection.tiles(prefs).contains(.music))
        XCTAssertEqual(Set(HomeSection.tiles(prefs)), Set(HomeSection.allCases).subtracting([.home, .music]))
    }

    func testTheSectionsShipInTheOrderTheyAreWrittenIn() {
        XCTAssertEqual(HomeSection.order(stored: []), HomeSection.allCases)
    }

    func testAStoredOrderIsFollowed() {
        let stored = [HomeSection.stats.rawValue, HomeSection.music.rawValue]
        let order = HomeSection.order(stored: stored)
        XCTAssertEqual(Array(order.prefix(2)), [.stats, .music])
        XCTAssertEqual(Set(order), Set(HomeSection.allCases), "and nothing is lost")
    }

    func testASectionTheStoredOrderNeverMentionedKeepsItsPlaceAtTheEnd() {
        // What an older build wrote will not name a section a later one added; it has to
        // appear rather than vanish.
        let order = HomeSection.order(stored: [HomeSection.notes.rawValue])
        XCTAssertEqual(order.first, .notes)
        XCTAssertEqual(order.count, HomeSection.allCases.count)
    }

    func testAnOrderWithRubbishInItIsStillAnOrder() {
        let order = HomeSection.order(stored: ["notes", "notes", "chocolate", ""])
        XCTAssertEqual(order.first, .notes)
        XCTAssertEqual(order.count, HomeSection.allCases.count, "no duplicates, no ghosts")
    }

    func testTheRingWalksTheSectionsInTheUsersOrder() {
        let prefs = Preferences.shared
        defer { prefs.sectionOrder = [] }
        prefs.sectionOrder = [HomeSection.stats.rawValue, HomeSection.notes.rawValue]
        let sections = center.ring.compactMap { view -> HomeSection? in
            guard case .home(let tab) = view else { return nil }
            return HomeSection(rawValue: tab)
        }
        XCTAssertEqual(Array(sections.prefix(2)), [.stats, .notes])
    }

    func testADigitReachesTheSlotTheUserPutThere() {
        let prefs = Preferences.shared
        defer { prefs.sectionOrder = [] }
        prefs.sectionOrder = [HomeSection.stats.rawValue]
        center.showHome()
        XCTAssertTrue(center.selectSlot(0))
        XCTAssertEqual(center.currentView, .home(tab: HomeSection.stats.rawValue))
    }

    // MARK: - The keyboard

    func testOnlyAPinnedNotesSectionOrALiveFindAsksForTheKeyboard() {
        XCTAssertFalse(center.wantsKeyboard, "an idle island never takes the keyboard")

        center.open(.home(tab: HomeSection.notes.rawValue))
        XCTAssertTrue(center.wantsKeyboard, "Notes is typed into")

        // The clipboard is a list until somebody starts a find in it; then the field is what
        // wants the keys, and it says so itself.
        center.open(.home(tab: HomeSection.clipboard.rawValue))
        XCTAssertFalse(center.wantsKeyboard, "nothing is being typed into yet")
        center.beginFind(with: "a")
        XCTAssertTrue(center.wantsKeyboard, "the find field is typed into")

        center.open(.home(tab: HomeSection.music.rawValue))
        XCTAssertFalse(center.wantsKeyboard, "nothing on the music section takes typing")

        center.open(.home(tab: HomeSection.notes.rawValue))
        center.collapse(reason: "test")
        XCTAssertFalse(center.wantsKeyboard, "a closed panel hands the keyboard straight back")
    }

    func testAPeekedNotesSectionDoesNotTakeTheKeyboard() {
        let exp = expectation(description: "peeking")
        center.setHovering(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        center.select(.home(tab: HomeSection.notes.rawValue))
        XCTAssertEqual(center.currentView, .home(tab: HomeSection.notes.rawValue))
        XCTAssertFalse(center.isOpen, "the pointer is only resting on the island")
        XCTAssertFalse(center.wantsKeyboard, "hovering must never take focus from the app in front")
    }

    /// Leaves the ring with Home and Now Playing and nothing else, whatever sections exist.
    /// Neither of those two has a switch, so neither can be taken out of it.
    private func onlyMusicSection() {
        HomeSection.allCases.forEach { $0.setEnabled(false, in: Preferences.shared) }
    }

    func testKeyboardRingCyclesActivitiesThenHomeTabsAndWraps() {
        onlyMusicSection()
        center.upsert(IslandActivity(id: "timer", kind: .timer,
                                     content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 90))
        XCTAssertEqual(center.keyboardRing, [.activity(id: "timer"), .home(tab: "home"), .home(tab: "music")])

        center.cycleView(forward: true)
        XCTAssertEqual(center.openView, .activity(id: "timer"))
        center.cycleView(forward: true)
        XCTAssertEqual(center.openView, .home(tab: "home"))
        XCTAssertEqual(center.presentation, .panel(.home(tab: "home")))
        center.cycleView(forward: true)
        XCTAssertEqual(center.openView, .home(tab: "music"))
        center.cycleView(forward: true)
        XCTAssertEqual(center.openView, .activity(id: "timer"), "wraps around")
        center.cycleView(forward: false)
        XCTAssertEqual(center.openView, .home(tab: "music"))
        center.collapse()
        center.cycleView(forward: false)
        XCTAssertEqual(center.openView, .home(tab: "music"), "backwards from closed lands on the last view")
        center.collapse()
        Preferences.shared.shelfEnabled = true
    }

    func testToggleOpensPrimaryThenCloses() {
        center.upsert(IslandActivity(id: "timer", kind: .timer,
                                     content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 90))
        center.toggle()
        XCTAssertEqual(center.presentation, .panel(.activity(id: "timer")), "shortcut opens the panel on the main activity")
        center.toggle()
        guard case .compact = center.presentation else { return XCTFail("shortcut closes it again") }
    }

    func testClickedAlertStaysUntilClosed() {
        let alert = IslandActivity(id: "bt", kind: .bluetooth,
                                   content: .bluetooth(BluetoothState(name: "AirPods", address: "", symbol: "airpods", batteryLeft: 50)),
                                   priority: 85)
        center.showAlert(alert, duration: 0.15)
        center.tap()
        XCTAssertEqual(center.presentation, .panel(.activity(id: "bt")), "clicking an alert opens its card in the panel")
        XCTAssertNil(center.alert, "the clicked alert lives on as an activity")

        let exp = expectation(description: "alert duration passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(center.isOpen, "its own timer must not close what the user opened")
        guard case .panel = center.presentation else { return XCTFail("still open after the alert would have expired") }

        center.collapse(reason: "test")
        XCTAssertFalse(center.isOpen)
        XCTAssertNil(center.activity(id: "bt"), "closing a held alert ends it")
        XCTAssertEqual(center.presentation, .idle, "nothing is left behind")
    }

    func testClosingAHeldAlertEndsItAndReleasesWhatWaited() {
        let airpods = IslandActivity(id: "bt", kind: .bluetooth,
                                     content: .bluetooth(BluetoothState(name: "AirPods", address: "", symbol: "airpods", batteryLeft: 50)),
                                     priority: 85)
        center.showAlert(airpods, duration: 5)
        center.tap()
        XCTAssertTrue(center.isOpen)
        // A finished download is a banner in the rail; the panel stays exactly where it is.
        let download = DownloadState(name: "movie.mkv", bytes: 100, total: 100, app: "Safari", isComplete: true)
        center.showAlert(IslandActivity(id: "dl", kind: .download, content: .download(download), priority: 85), duration: 5)
        XCTAssertEqual(center.overlayAlert?.id, "dl", "a routine alert shows as a banner over the open panel")
        XCTAssertEqual(center.presentation, .panel(.activity(id: "bt")), "a routine alert must not take the panel away")
        XCTAssertTrue(center.isOpen)

        let low = BatteryState(percent: 8, isCharging: false, isPluggedIn: false, event: .critical)
        center.showAlert(IslandActivity(id: "battery", kind: .battery, content: .battery(low), priority: 90), duration: 0.15)
        XCTAssertEqual(center.overlayAlert?.id, "battery", "a battery warning outranks the download and shows at once")
        XCTAssertEqual(center.presentation, .panel(.activity(id: "bt")), "the open panel stays under the banner")
        XCTAssertTrue(center.isOpen)

        let exp = expectation(description: "battery alert expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(center.overlayAlert?.id, "dl", "the download the warning replaced comes back once it expires")
        XCTAssertEqual(center.presentation, .panel(.activity(id: "bt")), "still open once the warning expires")

        center.collapse(reason: "test")
        XCTAssertFalse(center.isOpen)
        XCTAssertNil(center.activity(id: "bt"), "closing a held alert ends it")
        XCTAssertNil(center.alert, "the banner was seen; closing the panel does not replay it on the pill")
        XCTAssertEqual(center.presentation, .idle, "nothing is left behind")
    }

    func testAlertOverALiveActivityOfTheSameIdLeavesItOpenWhenItExpires() {
        let live = IslandActivity(id: "np", kind: .custom, content: .custom(CustomActivity(title: "Song")), priority: 50)
        center.upsert(live)
        center.showAlert(IslandActivity(id: "np", kind: .custom, content: .custom(CustomActivity(title: "Next song")), priority: 85), duration: 0.15)
        center.tap()
        XCTAssertEqual(center.openView, .activity(id: "np"))
        XCTAssertNotNil(center.alert, "an alert that annotates a live activity is not promoted")

        let exp = expectation(description: "alert expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertNil(center.alert)
        XCTAssertTrue(center.isOpen, "the live activity carries on")
        XCTAssertEqual(center.presentation, .panel(.activity(id: "np")))
        center.collapse(reason: "test")
    }

    func testVolumeHUDIsFeedbackNotACard() {
        let hud = IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: 0.5, isMuted: false)), priority: 85)
        center.showAlert(hud, duration: 5)
        center.tap()
        XCTAssertFalse(center.isOpen, "clicking a volume HUD opens nothing")
        center.toggle()
        guard case .home = center.openView else { return XCTFail("the shortcut goes to Home instead") }
        center.collapse(reason: "test")
        center.dismissAlert()
    }

    func testHUDOverAnOpenPanelIsAStripNotAReplacement() {
        center.open(.home(tab: "music"))
        XCTAssertEqual(center.presentation, .panel(.home(tab: "music")))
        let hud = IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: 0.5, isMuted: false)), priority: 85)
        center.showAlert(hud, duration: 5)
        XCTAssertEqual(center.presentation, .panel(.home(tab: "music")), "the panel stays")
        XCTAssertEqual(center.overlayAlert?.id, "hud")
        center.collapse(reason: "test")
        XCTAssertNil(center.overlayAlert, "closing the panel takes the strip with it")
        center.showAlert(hud, duration: 5)
        guard case .compact(let shown, _) = center.presentation else { return XCTFail("with nothing open the HUD has the island") }
        XCTAssertEqual(shown.id, "hud")
        center.dismissAlert()
    }

    func testTabStepsFromTheSectionPickedInTheSwitcher() {
        onlyMusicSection()
        Preferences.shared.shelfEnabled = true
        Preferences.shared.clipboardEnabled = true
        center.open(.home(tab: "music"))
        center.select(.home(tab: "clipboard"))
        XCTAssertEqual(center.openView, .home(tab: "clipboard"), "a switcher click moves a pinned panel")
        XCTAssertEqual(UserDefaults.standard.string(forKey: GestureRouter.homeTabKey), "clipboard", "and remembers the section")
        center.cycleView(forward: true)
        XCTAssertEqual(center.openView, .home(tab: "home"), "from the last section, Tab wraps to the first")
        center.cycleView(forward: true)
        XCTAssertEqual(center.openView, .home(tab: "music"))
        center.collapse()
    }

    func testPeekShowsTheRingUnderThePointerAndAClickPinsIt() {
        onlyMusicSection()
        Preferences.shared.shelfEnabled = true
        center.upsert(IslandActivity(id: "timer", kind: .timer,
                                     content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 90))
        center.setHovering(true)
        let exp = expectation(description: "hover applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(center.currentView, .activity(id: "timer"))
        XCTAssertFalse(center.isOpen)

        center.select(.home(tab: "shelf"))
        XCTAssertEqual(center.presentation, .panel(.home(tab: "shelf")), "the switcher moves the peek")
        XCTAssertFalse(center.isOpen, "without pinning it")
        XCTAssertTrue(center.step(forward: false, wrap: false))
        XCTAssertEqual(center.currentView, .home(tab: "music"))
        XCTAssertTrue(center.step(forward: false, wrap: false))
        XCTAssertEqual(center.currentView, .home(tab: "home"))
        XCTAssertTrue(center.step(forward: false, wrap: false))
        XCTAssertEqual(center.currentView, .activity(id: "timer"))
        XCTAssertFalse(center.step(forward: false, wrap: false), "a swipe stops at the end of the ring")

        center.tap()
        XCTAssertEqual(center.openView, .activity(id: "timer"), "a click pins what the pointer was showing")
        center.collapse(reason: "test")
        center.setHovering(false)
        let exp2 = expectation(description: "hover cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivityCenter.hoverExitGrace + 0.3) { exp2.fulfill() }
        wait(for: [exp2], timeout: 3)
        Preferences.shared.shelfEnabled = true
    }

    func testNowPlayingOpensItsHomeSectionAndNeverAppearsTwiceInTheRing() {
        onlyMusicSection()
        let track = NowPlayingService.fakeTrack()
        center.upsert(IslandActivity(id: "nowplaying", kind: .nowPlaying, content: .nowPlaying(track), priority: 50))
        XCTAssertEqual(center.keyboardRing, [.home(tab: "home"), .home(tab: "music")])
        center.tap()
        XCTAssertEqual(center.openView, .home(tab: "music"), "the music pill opens the Now Playing section")
        center.collapse(reason: "test")
    }
    // MARK: - What a new Mac is asked, and when

    /// Nothing asks the system for anything before the tour has been through. Starting the
    /// calendar asks macOS for it, and that sheet was the first thing a new Mac saw of this
    /// app — ahead of the window that introduces it, and ahead of the page where Today is
    /// offered as a switch.
    func testTheCalendarWaitsForTheTour() {
        let prefs = Preferences.shared
        let seen = prefs.hasSeenWelcome
        let calendar = prefs.calendarEnabled
        defer { prefs.hasSeenWelcome = seen; prefs.calendarEnabled = calendar }

        prefs.calendarEnabled = true
        prefs.hasSeenWelcome = false
        XCTAssertFalse(ServiceHub.wantsCalendar(prefs), "not before the tour")
        prefs.hasSeenWelcome = true
        XCTAssertTrue(ServiceHub.wantsCalendar(prefs), "and after it, if it is switched on")
        prefs.calendarEnabled = false
        XCTAssertFalse(ServiceHub.wantsCalendar(prefs), "never when it is switched off")
    }

    /// The same for the two folders macOS guards: a new Mac's first sight of the app was a
    /// prompt for Downloads and another for the screenshots folder, ahead of the tour.
    func testTheFolderWatchersWaitForTheTour() {
        let prefs = Preferences.shared
        let saved = (prefs.hasSeenWelcome, prefs.downloadsEnabled, prefs.screenshotsEnabled)
        defer { (prefs.hasSeenWelcome, prefs.downloadsEnabled, prefs.screenshotsEnabled) = saved }

        prefs.downloadsEnabled = true
        prefs.screenshotsEnabled = true
        prefs.hasSeenWelcome = false
        XCTAssertFalse(ServiceHub.wantsDownloads(prefs), "not before the tour")
        XCTAssertFalse(ServiceHub.wantsScreenshots(prefs), "not before the tour")
        prefs.hasSeenWelcome = true
        XCTAssertTrue(ServiceHub.wantsDownloads(prefs), "and after it, if it is switched on")
        XCTAssertTrue(ServiceHub.wantsScreenshots(prefs))
        prefs.downloadsEnabled = false
        prefs.screenshotsEnabled = false
        XCTAssertFalse(ServiceHub.wantsDownloads(prefs), "never when it is switched off")
        XCTAssertFalse(ServiceHub.wantsScreenshots(prefs))
    }

    // MARK: - The front door holds every tile there is

    func testTheGridWidensRatherThanLeaveASectionOffTheFrontDoor() {
        // The band beside the notch cannot hold every section at a size anybody can hit, so
        // the grid is the only place some of them appear at all. A section with no tile and
        // no slot is a section nobody will ever find.
        let prefs = Preferences.shared
        HomeSection.allCases.forEach { $0.setEnabled(true, in: prefs) }
        let everything = HomeSection.tiles(prefs)
        let columns = HomeGridView.columns(for: everything.count)
        XCTAssertGreaterThanOrEqual(HomeGridView.capacity(columns: columns), everything.count,
                                    "every section switched on at once still has somewhere to stand")
    }

    func testTheGridKeepsItsFiveColumnsUntilItHasTo() {
        XCTAssertEqual(HomeGridView.columns(for: 8), HomeGridView.columns)
        XCTAssertEqual(HomeGridView.columns(for: 9), HomeGridView.crowdedColumns, "and widens at the ninth")
        XCTAssertEqual(HomeGridView.capacity(columns: HomeGridView.columns), 8,
                       "three beside Now Playing and five underneath")
        XCTAssertEqual(HomeGridView.capacity(columns: HomeGridView.crowdedColumns), 10)
    }

    func testAWiderGridStillFitsTheColumnItIsDrawnIn() {
        for columns in [HomeGridView.columns, HomeGridView.crowdedColumns] {
            let width = HomeGridView.tileWidth(columns: columns)
            let used = CGFloat(columns) * width + CGFloat(columns - 1) * HomeGridView.gap
            XCTAssertLessThanOrEqual(used, IslandLayout.panelContentWidth, "\(columns) columns")
            XCTAssertGreaterThan(width, 90, "a tile narrower than this cannot hold a section's name")
            // The grid is drawn at exactly this width and centred, so what the rounding leaves
            // over — 2 pt at five columns, 4 at six — is split between the two sides rather
            // than all of it going to the right.
            XCTAssertEqual(HomeGridView.gridWidth(columns: columns), used, "\(columns) columns")
        }
    }

    // MARK: - What the outline is told about the last step

    func testAHoverExitForgetsWhichWayTheLastStepWent() {
        // `navigationDirection` picks the spring the outline grows on and the transition the
        // content arrives with. Only opening and collapsing used to clear it, and a hover exit
        // goes through neither — so once you had stepped sideways in a peeked panel, every
        // hover-open afterwards grew on the flat navigate spring and pushed its content in
        // from the side instead of crossing over. Opening the same panel twice looked like
        // two different apps.
        onlyMusicSection()
        center.setHovering(true)
        let shown = expectation(description: "hover applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { shown.fulfill() }
        wait(for: [shown], timeout: 2)

        center.select(.home(tab: "music"), direction: 1)
        XCTAssertEqual(center.navigationDirection, 1, "a step sideways is a direction")

        center.setHovering(false)
        let left = expectation(description: "hover cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivityCenter.hoverExitGrace + 0.3) { left.fulfill() }
        wait(for: [left], timeout: 3)
        XCTAssertEqual(center.navigationDirection, 0, "and leaving is not one")
    }

    // MARK: - Leaving for another app

    func testGoingToAnotherAppIsLeaving() {
        // The panel claims the whole alphabet as global hot keys while it is open. A click
        // outside used to be the only thing that closed it, and Command-Tab makes none — so a
        // reply typed in Mail went into a find in the island instead.
        XCTAssertTrue(ActivityCenter.isSomebodyElse("com.apple.mail", ours: "com.notchisland.app"))
    }

    func testTakingTheKeyboardForItsOwnFieldIsNotLeaving() {
        XCTAssertFalse(ActivityCenter.isSomebodyElse("com.notchisland.app", ours: "com.notchisland.app"))
    }

    func testAnAppThatWillNotSayWhoItIsDoesNotCloseThePanel() {
        XCTAssertFalse(ActivityCenter.isSomebodyElse(nil, ours: "com.notchisland.app"))
        XCTAssertFalse(ActivityCenter.isSomebodyElse("", ours: "com.notchisland.app"))
    }

    func testAnIslandWithNoIdentityStillGetsOutOfTheWay() {
        XCTAssertTrue(ActivityCenter.isSomebodyElse("com.apple.mail", ours: nil),
                      "a build with no bundle identifier must not be the one app that never yields")
    }

    // MARK: - The notification history

    func testNotificationsIsASectionWithASwitchOfItsOwn() {
        let prefs = Preferences.shared
        let saved = prefs.notificationsEnabled
        // Back to what it ships as rather than to what this suite left it on: every other
        // class here starts by switching the lot on, and this is the one that must not be.
        defer { prefs.notificationsEnabled = saved }
        prefs.notificationsEnabled = true
        XCTAssertTrue(HomeSection.notifications.isEnabled(prefs))
        XCTAssertTrue(HomeSection.available(prefs).contains(.notifications))
        XCTAssertTrue(HomeSection.tiles(prefs).contains(.notifications), "and a tile on the front door")
        HomeSection.notifications.setEnabled(false, in: prefs)
        XCTAssertFalse(HomeSection.notifications.isEnabled(prefs))
        XCTAssertFalse(HomeSection.available(prefs).contains(.notifications))
        XCTAssertFalse(HomeSection.tiles(prefs).contains(.notifications))
    }

    /// The one feature here that writes down what somebody's messages said. Nothing about it
    /// may start on any ground but the switch: not a section being opened, not the permission
    /// happening to be granted, not another switch implying it.
    func testNothingReadsABannerUntilTheSwitchSaysSo() {
        let prefs = Preferences.shared
        let saved = prefs.notificationsEnabled
        defer { prefs.notificationsEnabled = saved }

        prefs.notificationsEnabled = false
        XCTAssertFalse(ServiceHub.wantsNotifications(prefs), "off is off, whatever else is on")
        prefs.notificationsEnabled = true
        XCTAssertTrue(ServiceHub.wantsNotifications(prefs), "and on when it has been asked for")
    }

    func testTheNotificationHistoryIsAListYouCanTypeAt() {
        XCTAssertTrue(PanelFind.searches(.notifications),
                      "a history worth keeping is a history worth looking through")
    }

    // MARK: - A card under the pointer

    private func settle(_ seconds: TimeInterval) {
        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }

    /// A card with something on it to use, the way a screenshot's is.
    private func finishedDownload() -> IslandActivity {
        let done = DownloadState(name: "movie.mkv", bytes: 100, total: 100, app: "Safari", isComplete: true)
        return IslandActivity(id: "download-done", kind: .download, content: .download(done), priority: 85,
                              presentation: .expanded)
    }

    private func airPods() -> IslandActivity {
        IslandActivity(id: "bt", kind: .bluetooth,
                       content: .bluetooth(BluetoothState(name: "AirPods", address: "", symbol: "airpods", batteryLeft: 50)),
                       priority: 85)
    }

    func testACardUnderThePointerStaysACard() {
        // A quarter of a second after the pointer reached a screenshot's card it turned into
        // the Home peek, and the thumbnail and its Copy and Open moved out from under the hand
        // that was going to click them.
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        center.setHovering(true)
        settle(0.1)
        XCTAssertTrue(center.isHovering)
        guard case .card(let shown) = center.presentation else { return XCTFail("the card stays a card under the pointer") }
        XCTAssertEqual(shown.id, "download-done")
        XCTAssertNil(center.overlayAlert, "and is not a banner in a peek's rail as well")
        center.tap()
        XCTAssertEqual(center.openView, .activity(id: "download-done"), "a click on it opens it, as ever")
        XCTAssertNil(center.alert, "held, as a clicked alert is")
    }

    func testAPillAlertStillYieldsToThePeek() {
        // Only a card there to be used holds. News that reads at a glance becomes a banner in
        // the panel the pointer opened.
        center.showAlert(airPods(), duration: 5, haptic: false)
        center.setHovering(true)
        settle(0.1)
        guard case .panel = center.presentation else { return XCTFail("the peek") }
        XCTAssertEqual(center.overlayAlert?.id, "bt")
    }

    func testACardArrivingInAPeekInUseIsABannerThere() {
        // The hand is in the peek — on the volume, reading Today. A finished download's card
        // used to tear the peek down under it; it is a banner in the peek's rail, as before.
        center.setHovering(true)
        settle(0.1)
        guard case .panel(let peek) = center.presentation else { return XCTFail("the peek") }
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        XCTAssertEqual(center.presentation, .panel(peek), "the peek stays where the hand is")
        XCTAssertEqual(center.overlayAlert?.id, "download-done", "and the card is a banner in it")
        XCTAssertFalse(center.isOpen)
    }

    func testACardHoldsAgainstThePeekOnlyIfItWasThereFirst() {
        let shown = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(ActivityCenter.cardHoldsAgainstPeek(holdsCard: true, shownAt: shown,
                                                          pointerArrivedAt: shown.addingTimeInterval(0.3)),
                      "the card first: the pointer arriving is the hand going to it")
        XCTAssertFalse(ActivityCenter.cardHoldsAgainstPeek(holdsCard: true, shownAt: shown.addingTimeInterval(0.3),
                                                           pointerArrivedAt: shown),
                       "the peek first: it was in use, and the card is a banner in it")
        XCTAssertFalse(ActivityCenter.cardHoldsAgainstPeek(holdsCard: false, shownAt: shown,
                                                           pointerArrivedAt: shown.addingTimeInterval(0.3)),
                       "a pill yields to the peek whichever came first")
    }

    func testACardOutlastsItsTimeWhileThePointerIsOnIt() {
        center.showAlert(finishedDownload(), duration: 1.6, exact: true, haptic: false)
        center.setHovering(true)
        settle(1.9)
        XCTAssertEqual(center.alert?.id, "download-done", "its time is up, but the hand is on it")
        // Past the second look, a second after the first: that look was asked about the one
        // second it had been re-armed for, and the card went from under the hand there.
        settle(1.0)
        XCTAssertEqual(center.alert?.id, "download-done", "and it stays while the hand does, not one second more")
        center.setHovering(false)
        settle(ActivityCenter.hoverExitGrace + 1.2)
        XCTAssertNil(center.alert, "and it goes once the pointer has")
    }

    func testWhenAnAlertTakesTheIsland() {
        XCTAssertTrue(ActivityCenter.alertTakesIsland(rank: 3, holdsCard: false, peeking: false, forcedCardUp: false),
                      "nothing in its way")
        XCTAssertFalse(ActivityCenter.alertTakesIsland(rank: 4, holdsCard: false, peeking: true, forcedCardUp: false),
                       "a pill under the pointer yields to the peek")
        XCTAssertTrue(ActivityCenter.alertTakesIsland(rank: 3, holdsCard: true, peeking: true, forcedCardUp: false),
                      "a card there to be used holds against it")
        XCTAssertFalse(ActivityCenter.alertTakesIsland(rank: 5, holdsCard: true, peeking: false, forcedCardUp: true),
                       "a ringing timer keeps its card")
        XCTAssertFalse(ActivityCenter.alertTakesIsland(rank: 1, holdsCard: false, peeking: false, forcedCardUp: true),
                       "a volume key does not fold it to a pill")
        XCTAssertTrue(ActivityCenter.alertTakesIsland(rank: 6, holdsCard: false, peeking: true, forcedCardUp: true),
                      "a battery about to run out goes over everything but a pinned panel")
    }

    func testWhenAnAlertOutstaysItsTime() {
        XCTAssertTrue(ActivityCenter.alertHolds(seconds: 4, heldFor: 0, pointerOn: true, panelShowing: false,
                                                cardUnderPointer: false),
                      "the pointer on the pill")
        XCTAssertTrue(ActivityCenter.alertHolds(seconds: 4, heldFor: 0, pointerOn: true, panelShowing: true,
                                                cardUnderPointer: true),
                      "a card under the pointer, with the pointer opening the panel as it ships")
        XCTAssertFalse(ActivityCenter.alertHolds(seconds: 4, heldFor: 0, pointerOn: true, panelShowing: true,
                                                 cardUnderPointer: false),
                       "a banner in the rail goes on its own time")
        XCTAssertFalse(ActivityCenter.alertHolds(seconds: 1, heldFor: 0, pointerOn: true, panelShowing: false,
                                                 cardUnderPointer: true),
                       "a copied line goes whatever, since the click that copied left the pointer there")
        XCTAssertFalse(ActivityCenter.alertHolds(seconds: 4, heldFor: 0, pointerOn: false, panelShowing: false,
                                                 cardUnderPointer: false))
    }

    func testTheLookASecondLaterIsAskedAboutTheAlertsOwnLength() {
        // Re-armed a second at a time, each look is asked about the length the alert was shown
        // for. Asked about that one second, as it was, the card went at the second look.
        XCTAssertTrue(ActivityCenter.alertHolds(seconds: 4, heldFor: 1, pointerOn: true, panelShowing: true,
                                                cardUnderPointer: true))
        XCTAssertTrue(ActivityCenter.alertHolds(seconds: 1.6, heldFor: 30, pointerOn: true, panelShowing: true,
                                                cardUnderPointer: true))
        XCTAssertFalse(ActivityCenter.alertHolds(seconds: 1, heldFor: 1, pointerOn: true, panelShowing: true,
                                                 cardUnderPointer: true),
                       "what the second look used to ask, and why the card went from under the hand")
    }

    func testTheHoldOnAnAlertHasAnEnd() {
        XCTAssertTrue(ActivityCenter.alertHolds(seconds: 4, heldFor: ActivityCenter.alertHoldLimit - 1, pointerOn: true,
                                                panelShowing: false, cardUnderPointer: false))
        XCTAssertFalse(ActivityCenter.alertHolds(seconds: 4, heldFor: ActivityCenter.alertHoldLimit, pointerOn: true,
                                                 panelShowing: false, cardUnderPointer: true),
                       "a hand left resting over the notch is not somebody still reading")
        XCTAssertEqual(ActivityCenter.alertHoldLimit, ActivityCenter.forcedHoldLimit, "the minute a forced card gets")
    }

    func testOnlyACardWithAViewOfItsOwnHolds() {
        XCTAssertTrue(ActivityCenter.holdsCard(finishedDownload()))
        var pill = finishedDownload()
        pill.presentation = .compact
        XCTAssertFalse(ActivityCenter.holdsCard(pill), "a pill is news, not a card to use")
        let unlock = IslandActivity(id: "unlock", kind: .unlock, content: .unlock, priority: 85, presentation: .expanded)
        XCTAssertFalse(ActivityCenter.holdsCard(unlock), "asked for a card, but it has none to show")
    }

    /// With "Open from the empty notch too" off the pointer on the bare notch opens nothing,
    /// but a card that arrived there counted as yielding to that peek: nothing was drawn at
    /// all, card or peek.
    func testACardArrivingOnTheBareNotchIsDrawnWhenThePointerOpensNothingThere() {
        Preferences.shared.expandOnIdleHover = false
        center.setHovering(true)
        settle(0.1)
        XCTAssertTrue(center.isHovering)
        XCTAssertEqual(center.presentation, .idle, "nothing live, and nothing to peek at")
        XCTAssertFalse(center.isPanelShowing)
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        guard case .card(let shown) = center.presentation else { return XCTFail("the card, where it was drawn nowhere") }
        XCTAssertEqual(shown.id, "download-done")
        XCTAssertNil(center.overlayAlert, "and not a banner over a panel that is not there")

        center.showAlert(airPods(), duration: 5, haptic: false)
        guard case .compact(let pill, _) = center.presentation else { return XCTFail("a pill alert is a pill") }
        XCTAssertEqual(pill.id, "bt")
    }

    // MARK: - A card forced up

    private func rungTimer() -> IslandActivity {
        IslandActivity(id: "timer", kind: .timer,
                       content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(), isFinished: true)), priority: 90)
    }

    func testARingingTimerKeepsItsCardAgainstALowerAlert() {
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 5)
        let hud = IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: 0.5, isMuted: false)), priority: 85)
        center.showAlert(hud, duration: 1.5, haptic: false)
        guard case .card(let shown) = center.presentation else { return XCTFail("the ringing card stays a card") }
        XCTAssertEqual(shown.id, "timer", "with its Stop where it was")
        let low = BatteryState(percent: 8, isCharging: false, isPluggedIn: false, event: .low)
        center.showAlert(IslandActivity(id: "battery", kind: .battery, content: .battery(low), priority: 90), duration: 5, haptic: false)
        XCTAssertEqual(center.presentation.primary?.id, "battery", "a battery about to run out still goes over it")
    }

    func testWhatArrivesUnderARingingCardWaitsForIt() {
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 0.2)
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        XCTAssertNil(center.alert, "behind the card, not under it")
        settle(0.5)
        XCTAssertNil(center.forcedExpandedID)
        XCTAssertEqual(center.alert?.id, "download-done", "and its turn comes when the card goes")
    }

    func testAnAlertAlreadyUpGoesBehindTheRingingCard() {
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 0.2)
        guard case .card(let shown) = center.presentation else { return XCTFail("the ringing card") }
        XCTAssertEqual(shown.id, "timer")
        settle(0.5)
        XCTAssertEqual(center.alert?.id, "download-done", "a finished download the ring covered is not lost")
    }

    func testARingingCardUnderThePointerWaitsForItToLeave() {
        // With the pointer resting on it, the card grew into the peek panel when its eight
        // seconds ran out, and moved Stop from under the hand on its way there.
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 0.2)
        center.setHovering(true)
        settle(0.5)
        XCTAssertEqual(center.forcedExpandedID, "timer", "its time is up, but the hand is on it")
        guard case .card = center.presentation else { return XCTFail("still the card, not the peek panel") }
    }

    func testAnAlertSentBehindTheRingingCardKeepsItsOwnLength() {
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 5)
        XCTAssertEqual(center.pendingAlerts.map(\.activity.id), ["download-done"])
        XCTAssertEqual(center.pendingAlerts.first?.duration, 5, "its own five seconds, not the default 1.8")
    }

    func testAnAlertAWarningPushesAsideKeepsItsOwnLength() {
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        let low = BatteryState(percent: 8, isCharging: false, isPluggedIn: false, event: .low)
        center.showAlert(IslandActivity(id: "battery", kind: .battery, content: .battery(low), priority: 90), duration: 5, haptic: false)
        XCTAssertEqual(center.alert?.id, "battery")
        XCTAssertEqual(center.pendingAlerts.first?.activity.id, "download-done")
        XCTAssertEqual(center.pendingAlerts.first?.duration, 5)
    }

    func testTimeBehindARingingCardDoesNotCountAgainstAnAlertsPatience() {
        // Eight seconds of ringing and a minute under the pointer, against twenty of patience.
        XCTAssertFalse(ActivityCenter.outwaited(finishedDownload(), waited: 68, behindHold: true),
                       "a finished download that waited behind the card is still news when it goes")
        XCTAssertTrue(ActivityCenter.outwaited(finishedDownload(), waited: 21, behindHold: false))
        XCTAssertFalse(ActivityCenter.outwaited(finishedDownload(), waited: 19, behindHold: false))
        let hud = IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: 0.5, isMuted: false)), priority: 85)
        XCTAssertTrue(ActivityCenter.outwaited(hud, waited: 5, behindHold: true),
                      "a volume tick from a while ago is stale behind the card as anywhere")
    }

    func testWhenTheCardGoesWhatWaitedStartsItsPatienceAgain() {
        let queued = Date(timeIntervalSince1970: 1_790_000_000)
        let gone = queued.addingTimeInterval(68)
        let hud = IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: 0.5, isMuted: false)), priority: 85)
        let queue = [ActivityCenter.PendingAlert(activity: finishedDownload(), queuedAt: queued, duration: 5, exact: false),
                     ActivityCenter.PendingAlert(activity: hud, queuedAt: queued, duration: 1.5, exact: false)]
        let after = ActivityCenter.afterHold(queue, now: gone)
        XCTAssertEqual(after.map(\.queuedAt), [gone, queued], "the download from now, the HUD left to go stale")
        XCTAssertEqual(after.first?.duration, 5, "and nothing else about it changes")
    }

    func testTheHoldOnAForcedCardHasAnEnd() {
        XCTAssertTrue(ActivityCenter.forcedCardHolds(underPointer: true, heldFor: 0))
        XCTAssertFalse(ActivityCenter.forcedCardHolds(underPointer: false, heldFor: 0), "nobody on it: it goes on time")
        XCTAssertFalse(ActivityCenter.forcedCardHolds(underPointer: true, heldFor: ActivityCenter.forcedHoldLimit),
                       "a hand left resting over the notch is not somebody still deciding")
    }

    // MARK: - A full queue

    private func pending(_ activity: IslandActivity, at seconds: TimeInterval) -> ActivityCenter.PendingAlert {
        ActivityCenter.PendingAlert(activity: activity, queuedAt: Date(timeIntervalSince1970: 1_790_000_000 + seconds),
                                    duration: 4, exact: false)
    }

    private func charging() -> IslandActivity {
        let charging = BatteryState(percent: 40, isCharging: true, isPluggedIn: true, event: .pluggedIn)
        return IslandActivity(id: "battery", kind: .battery, content: .battery(charging), priority: 90)
    }

    /// Behind a card that holds the queue for minutes, the three alerts that got there first
    /// kept their places for good, and a charger going in after them was never shown.
    func testALouderArrivalTakesTheQuietestPlaceInAFullQueue() {
        let full = [pending(finishedDownload(), at: 0), pending(custom("note"), at: 1), pending(custom("later"), at: 2)]
        XCTAssertEqual(ActivityCenter.pendingLimit, 3)
        let after = ActivityCenter.admitting(pending(charging(), at: 3), to: full)
        XCTAssertEqual(after.map(\.activity.id), ["download-done", "later", "battery"],
                       "the quietest goes, and of the two quietest the one that has waited longest")

        let quiet = ActivityCenter.admitting(pending(custom("another"), at: 3), to: full)
        XCTAssertEqual(quiet.map(\.activity.id), ["download-done", "note", "later"],
                       "no louder than the quietest waiting: it is the one left out")
        let roomy = ActivityCenter.admitting(pending(custom("another"), at: 3), to: Array(full.prefix(2)))
        XCTAssertEqual(roomy.map(\.activity.id), ["download-done", "note", "another"], "with room, it simply joins")
    }

    func testAChargerArrivingBehindARingingCardAndAFullQueueIsNotLost() {
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 5)
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        center.showAlert(custom("note"), duration: 5, haptic: false)
        center.showAlert(custom("later"), duration: 5, haptic: false)
        XCTAssertEqual(center.pendingAlerts.count, 3)
        center.showAlert(charging(), duration: 5, haptic: false)
        XCTAssertEqual(center.pendingAlerts.map(\.activity.id), ["download-done", "later", "battery"])
    }

    // MARK: - What waits behind an alert the pointer holds

    /// A finished download's card held under the pointer for its minute kept a quieter alert
    /// queued behind it counting its twenty seconds, and that alert was dropped unseen when
    /// the card went. Its patience starts again when the card goes, as behind a forced card.
    func testWhatWaitedBehindAHeldCardStartsItsPatienceAgainWhenTheCardGoes() {
        center.showAlert(finishedDownload(), duration: 1.6, exact: true, haptic: false)
        center.showAlert(custom("note"), duration: 5, haptic: false)
        center.showAlert(custom("later"), duration: 5, haptic: false)
        XCTAssertEqual(center.pendingAlerts.count, 2, "both wait behind the louder card")
        center.setHovering(true)
        settle(1.9)
        XCTAssertEqual(center.alert?.id, "download-done", "held past its time under the pointer")
        let released = Date()
        center.setHovering(false)
        settle(ActivityCenter.hoverExitGrace + 1.2)
        XCTAssertNotEqual(center.alert?.id, "download-done", "gone once the pointer has")
        XCTAssertEqual(center.pendingAlerts.count, 1, "one of the two has its turn, and the other still waits")
        XCTAssertGreaterThanOrEqual(center.pendingAlerts.first?.queuedAt ?? .distantPast, released,
                                    "counting its patience from when the card went, not from when it was queued")
    }

    // MARK: - What waits behind a held alert

    func testEndingAHeldAlertLetsWhatWaitedBehindItThrough() {
        center.showAlert(airPods(), duration: 5, haptic: false)
        center.showAlert(custom("note"), duration: 5, haptic: false)
        XCTAssertEqual(center.alert?.id, "bt", "the quieter alert waits behind the louder one")
        center.tap()
        XCTAssertEqual(center.openView, .activity(id: "bt"))
        // Its own close button, rather than a close of the panel.
        center.end(id: "bt")
        XCTAssertFalse(center.isOpen)
        XCTAssertEqual(center.alert?.id, "note", "what waited behind it is shown now, not dropped when its patience runs out")
    }

    // MARK: - When the island next wakes

    func testTheIslandWakesForTheSoonestExpiryAndForNothingElse() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var soon = custom("soon")
        soon.expiresAt = now.addingTimeInterval(30)
        var later = custom("later")
        later.expiresAt = now.addingTimeInterval(600)
        let forever = custom("forever")
        XCTAssertNil(ActivityCenter.nextWake(activities: [], pausedUntil: 0, now: now),
                     "nothing to run out: nothing armed, where a timer used to look every second")
        XCTAssertNil(ActivityCenter.nextWake(activities: [forever], pausedUntil: 0, now: now))
        XCTAssertEqual(ActivityCenter.nextWake(activities: [later, forever, soon], pausedUntil: 0, now: now),
                       now.addingTimeInterval(30))
        var gone = custom("gone")
        gone.expiresAt = now.addingTimeInterval(-5)
        XCTAssertEqual(ActivityCenter.nextWake(activities: [later, gone], pausedUntil: 0, now: now), now,
                       "one already past is due now")
    }

    func testTheEndOfAPauseIsAWakeWhileItIsStillToCome() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var later = custom("later")
        later.expiresAt = now.addingTimeInterval(600)
        let pauseEnd = now.timeIntervalSince1970 + 60
        XCTAssertEqual(ActivityCenter.nextWake(activities: [], pausedUntil: pauseEnd, now: now), now.addingTimeInterval(60),
                       "a pause persisted across a relaunch has no timer of its own")
        XCTAssertEqual(ActivityCenter.nextWake(activities: [later], pausedUntil: pauseEnd, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(ActivityCenter.nextWake(activities: [later], pausedUntil: now.timeIntervalSince1970 - 1, now: now),
                       now.addingTimeInterval(600), "a pause that has ended is not waited for again")
        XCTAssertLessThan(ActivityCenter.expiryTolerance, 1, "inside the second the old look could be late by")
    }

    func testAnActivityStillGoesAtItsTime() {
        var brief = custom("brief")
        brief.expiresAt = Date().addingTimeInterval(0.3)
        center.upsert(brief)
        XCTAssertNotNil(center.activity(id: "brief"))
        settle(0.3 + ActivityCenter.expiryTolerance + 0.3)
        XCTAssertNil(center.activity(id: "brief"), "ended by the timer armed for it")
    }

    // MARK: - The sneak peek

    func testTheSneakPeekOverNowPlayingKeepsItsBubble() {
        // With files on the shelf, every track change popped the bubble out and back and
        // crossed the whole pill over, the cover that was staying put blurred with it.
        let track = NowPlayingService.fakeTrack()
        center.upsert(IslandActivity(id: "nowplaying", kind: .nowPlaying, content: .nowPlaying(track), priority: 50))
        center.upsert(IslandActivity(id: "shelf", kind: .shelf, content: .shelf(ShelfState(count: 2)), priority: 30))
        guard case .compact(_, let before) = center.presentation, before?.id == "shelf" else {
            return XCTFail("the shelf waits in the bubble")
        }
        let peek = IslandActivity(id: NowPlayingService.peekAlertID, kind: .nowPlaying, content: .nowPlaying(track), priority: 60)
        center.showAlert(peek, duration: 2.4, haptic: false)
        guard case .compact(let shown, let bubble) = center.presentation else { return XCTFail("the peek is a pill") }
        XCTAssertEqual(shown.id, NowPlayingService.peekAlertID)
        XCTAssertEqual(bubble?.id, "shelf", "the bubble stays where it was")
        XCTAssertEqual(IslandLayout.activityUnder(peek, center: center)?.id, "nowplaying",
                       "the pill keeps Now Playing's cover and identity; only the trailing slot changes")
    }

    func testTheSneakPeekIsDrawnOverOnlyTheMusicItIsAbout() {
        let track = NowPlayingService.fakeTrack()
        let peek = IslandActivity(id: NowPlayingService.peekAlertID, kind: .nowPlaying, content: .nowPlaying(track), priority: 60)
        let music = IslandActivity(id: "nowplaying", kind: .nowPlaying, content: .nowPlaying(track), priority: 50)
        let timer = custom("timer", priority: 90, kind: .timer)
        XCTAssertTrue(IslandLayout.isDrawnOver(peek, primary: music))
        XCTAssertFalse(IslandLayout.isDrawnOver(peek, primary: timer), "over a timer the peek is news, and has the pill")
        let hud = IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: 0.5, isMuted: false)), priority: 85)
        XCTAssertTrue(IslandLayout.isDrawnOver(hud, primary: timer), "a key press is drawn over anything live")
        XCTAssertFalse(IslandLayout.isDrawnOver(custom("note"), primary: music), "news is drawn in its place")
    }

    // MARK: - A right-click, and Escape

    func testARightClickInsideTheHoverDelayLeavesThePeekUngrown() {
        // The context menu opens over the island; the peek used to grow behind it.
        Preferences.shared.hoverDelay = 0.2
        center.setHovering(true)
        center.holdOpen(for: 15)
        settle(0.4)
        XCTAssertNil(center.hoverPanel, "nothing grew behind the menu")
        XCTAssertEqual(center.presentation, .idle)
    }

    func testEscapeIsTheIslandsOnlyOnceTheKeyboardWasAskedFor() {
        XCTAssertFalse(ActivityCenter.armsEscape(isOpen: true, invited: false, holdsKeyboard: false, heldByAnotherOfOurs: false),
                       "a click on a control pinned it: Escape is still the app's in front")
        XCTAssertTrue(ActivityCenter.armsEscape(isOpen: true, invited: true, holdsKeyboard: false, heldByAnotherOfOurs: false))
        XCTAssertTrue(ActivityCenter.armsEscape(isOpen: true, invited: false, holdsKeyboard: true, heldByAnotherOfOurs: false),
                      "the island holds the keyboard anyway, as for Notes")
        XCTAssertFalse(ActivityCenter.armsEscape(isOpen: true, invited: true, holdsKeyboard: true, heldByAnotherOfOurs: true),
                       "Settings or Quick Look has it")
        XCTAssertFalse(ActivityCenter.armsEscape(isOpen: false, invited: true, holdsKeyboard: true, heldByAnotherOfOurs: false),
                       "nothing open, nothing to close")
    }

    func testAClickOnAControlLeavesEscapeWithTheAppInFront() {
        center.setHovering(true)
        settle(0.1)
        center.pinPeek(panel: "main")
        XCTAssertTrue(center.isOpen)
        XCTAssertFalse(center.escapeArmed, "the hand that clicked pause is going back to its typing")
        center.tap()
        XCTAssertTrue(center.escapeArmed, "a click on the island's body asks for the keyboard, and Escape comes with it")
    }

    // MARK: - A card that takes the place of a peek

    /// How long since the panel opened, as `NotchPanel.sendEvent` asks it.
    private var sinceOpened: TimeInterval { Date().timeIntervalSince(center.openedAt) }

    func testACardThatTakesThePeeksPlaceGivesTheClickAimedAtThePeekToItsBody() {
        // Watching the timer in a peek when it rang: the card took the peek's place, and the
        // click already on its way pressed Stop.
        center.upsert(rungTimer())
        center.setHovering(true)
        settle(NotchPanel.growthGuard + 0.3)
        guard case .panel = center.presentation(for: "main") else { return XCTFail("the peek") }
        XCTAssertFalse(NotchPanel.clickGoesToBody(sinceGrew: center.sinceGrew(on: "main"), clickCount: 1,
                                                  sinceOpened: sinceOpened),
                       "a peek that has settled takes its own clicks")

        center.forceExpanded(id: "timer", for: 5)
        guard case .card(let card) = center.presentation(for: "main") else { return XCTFail("the ringing card") }
        XCTAssertEqual(card.id, "timer")
        XCTAssertTrue(center.guardsClicks(on: "main"), "a card is read by the growth guard as a panel is")
        XCTAssertTrue(NotchPanel.clickGoesToBody(sinceGrew: center.sinceGrew(on: "main"), clickCount: 1,
                                                 sinceOpened: sinceOpened),
                      "the click aimed at the peek goes to the card's body, not to Stop")
        center.tap(panel: "main")
        XCTAssertEqual(center.openView, .activity(id: "timer"), "and the body opens the card, as a click on it does")
    }

    func testABatteryAboutToRunOutOverAPeekIsGrowthToo() {
        center.setHovering(true)
        settle(NotchPanel.growthGuard + 0.3)
        guard case .panel = center.presentation(for: "main") else { return XCTFail("the peek") }
        let low = BatteryState(percent: 8, isCharging: false, isPluggedIn: false, event: .low)
        center.showAlert(IslandActivity(id: "battery", kind: .battery, content: .battery(low), priority: 90),
                         duration: 5, haptic: false)
        guard case .card(let card) = center.presentation(for: "main") else { return XCTFail("the warning's card") }
        XCTAssertEqual(card.id, "battery")
        XCTAssertLessThan(center.sinceGrew(on: "main"), NotchPanel.growthGuard)
    }

    func testWhatCountsAsACardTakingAnIslandsPlace() {
        let timer = rungTimer()
        let peek = IslandPresentation.panel(.home(tab: HomeSection.music.rawValue))
        XCTAssertTrue(ActivityCenter.cardReplaces(peek, with: .card(timer)))
        XCTAssertTrue(ActivityCenter.cardReplaces(.compact(timer, bubble: nil), with: .card(timer)), "the pill grew into it")
        XCTAssertTrue(ActivityCenter.cardReplaces(.card(finishedDownload()), with: .card(timer)), "another card's buttons")
        XCTAssertFalse(ActivityCenter.cardReplaces(.card(timer), with: .card(timer)), "the same card, updated")
        XCTAssertFalse(ActivityCenter.cardReplaces(.card(timer), with: peek), "a card going is not a card arriving")
        XCTAssertFalse(ActivityCenter.cardReplaces(.idle, with: .compact(timer, bubble: nil)))
    }

    /// With the pointer on a card that held against the peek, a click holds the alert — which
    /// takes it off the island — before it opens the card's panel, and the island was asked
    /// whether it grew after that: the peek under the card said a panel was already showing.
    func testAClickedCardGrowingIntoThePanelUnderThePointerIsGrowth() {
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        center.setHovering(true)
        settle(NotchPanel.growthGuard + 0.3)
        guard case .card = center.presentation(for: "main") else { return XCTFail("the card holds against the peek") }
        XCTAssertGreaterThan(center.sinceGrew(on: "main"), NotchPanel.growthGuard, "nothing grew when the pointer came")
        center.tap(panel: "main")
        XCTAssertEqual(center.openView, .activity(id: "download-done"))
        XCTAssertNil(center.alert, "held, as a clicked alert is")
        XCTAssertLessThan(center.sinceGrew(on: "main"), NotchPanel.growthGuard,
                          "the card grew into the panel, so a quick second click is the body's")
    }

    // MARK: - A peek left over

    func testAPeekIsNotSeededUnderAPinnedPanelNorKeptPastIt() {
        // Pinned on a section, with the pointer coming to rest on it: the peek it seeded
        // outlived a close that did not go through `collapse`, and the next hover opened on
        // that section instead of on what had started playing since.
        center.open(.home(tab: HomeSection.clipboard.rawValue))
        center.setHovering(true)
        settle(0.1)
        XCTAssertEqual(center.hoverPanel, "main")
        XCTAssertNil(center.peekView, "an island the panel is pinned on shows no peek, and seeds none")
        center.upsert(IslandActivity(id: "nowplaying", kind: .nowPlaying, content: .nowPlaying(NowPlayingService.fakeTrack()),
                                     priority: 50))
        center.clearInteraction()
        XCTAssertFalse(center.isOpen)
        XCTAssertNil(center.peekView, "no pointer on any island, no peek")
        center.setHovering(true)
        settle(0.1)
        XCTAssertEqual(center.currentView, .home(tab: HomeSection.music.rawValue), "the peek opens on what is playing")
    }

    // MARK: - Time that passed without the expiry timer

    /// The expiry timer counts only time the Mac is awake, and a card with a `ttl` outlived its
    /// time by as long as the Mac slept. Waking, or the clock being set, is a look straight away.
    func testWakingPrunesWhatRanOutWhileTheMacSlept() {
        var card = custom("api-ttl")
        card.expiresAt = Date().addingTimeInterval(600)
        center.upsert(card)
        center.upsert(custom("api-stays"))
        center.timeMoved(now: Date().addingTimeInterval(3600))
        XCTAssertNil(center.activity(id: "api-ttl"), "its ten minutes went by while the lid was shut")
        XCTAssertNotNil(center.activity(id: "api-stays"), "a card with no time of its own stays")
        center.timeMoved()
        XCTAssertNotNil(center.activity(id: "api-stays"))
    }

    func testTheWakeRuleStillNamesTheSoonestEnd() {
        let now = Date()
        var soon = custom("a")
        soon.expiresAt = now.addingTimeInterval(60)
        var late = custom("b")
        late.expiresAt = now.addingTimeInterval(600)
        XCTAssertEqual(ActivityCenter.nextWake(activities: [late, soon], pausedUntil: 0, now: now), soon.expiresAt)
        XCTAssertEqual(ActivityCenter.nextWake(activities: [late, soon], pausedUntil: 0, now: now.addingTimeInterval(3600)),
                       now.addingTimeInterval(3600), "an end the clock has passed is due now")
    }

    // MARK: - A key press over the sneak peek

    private func volumeHUD() -> IslandActivity {
        IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: 0.5, isMuted: false)), priority: 85)
    }

    private func sneakPeek() -> IslandActivity {
        IslandActivity(id: NowPlayingService.peekAlertID, kind: .nowPlaying,
                       content: .nowPlaying(NowPlayingService.fakeTrack()), priority: 60)
    }

    /// A volume, brightness or mute press during the peek's 2.4 seconds was queued behind it with
    /// two seconds of patience, and dropped when its turn came: the key was taken, and no bezel
    /// from anybody said so.
    func testAKeyPressDuringTheSneakPeekIsShownAtOnce() {
        center.showAlert(sneakPeek(), duration: 2.4, haptic: false)
        center.showAlert(volumeHUD(), duration: 1.5, haptic: false)
        XCTAssertEqual(center.alert?.id, "hud")
        XCTAssertTrue(center.pendingAlerts.isEmpty, "and the peek is not kept for afterwards")
    }

    func testOnlyAKeyPressTakesThePeeksPlace() {
        XCTAssertFalse(ActivityCenter.waitsBehind(sneakPeek(), arriving: volumeHUD()))
        XCTAssertFalse(ActivityCenter.waitsBehind(sneakPeek(), arriving: custom("capslock")), "Caps Lock is a key too")
        XCTAssertTrue(ActivityCenter.waitsBehind(finishedDownload(), arriving: volumeHUD()), "behind anything else it waits, as before")
        XCTAssertTrue(ActivityCenter.waitsBehind(finishedDownload(), arriving: sneakPeek()))
        XCTAssertFalse(ActivityCenter.waitsBehind(nil, arriving: volumeHUD()))
        XCTAssertFalse(ActivityCenter.waitsBehind(volumeHUD(), arriving: volumeHUD()), "the same alert again is an update")
        XCTAssertFalse(ActivityCenter.waitsBehind(volumeHUD(), arriving: sneakPeek()), "a louder one replaces a key press")
    }

    /// A peek queued behind a finished download came up to twenty seconds after its track began,
    /// for a track that may have stopped meanwhile.
    func testAQueuedSneakPeekGoesStaleInAMoment() {
        XCTAssertEqual(ActivityCenter.patience(for: sneakPeek()), ActivityCenter.peekPatience)
        XCTAssertFalse(ActivityCenter.outwaited(sneakPeek(), waited: 2.5, behindHold: false))
        XCTAssertTrue(ActivityCenter.outwaited(sneakPeek(), waited: 3.5, behindHold: false))
        XCTAssertTrue(ActivityCenter.outwaited(sneakPeek(), waited: 3.5, behindHold: true), "a hold is no reason to keep it")
        XCTAssertFalse(ActivityCenter.keepsThroughHold(sneakPeek()))
        XCTAssertTrue(ActivityCenter.keepsThroughHold(finishedDownload()))
        XCTAssertFalse(ActivityCenter.keepsThroughHold(volumeHUD()))
        let queued = Date(timeIntervalSince1970: 1_790_000_000)
        let after = ActivityCenter.afterHold([ActivityCenter.PendingAlert(activity: sneakPeek(), queuedAt: queued, duration: 2.4, exact: false)],
                                             now: queued.addingTimeInterval(30))
        XCTAssertEqual(after.first?.queuedAt, queued, "its patience is not started again when the hold ends")
    }

    // MARK: - A question taking the island back

    func testTheQueueWaitsForAQuestionOnlyWhileOneIsUpWithItsCard() {
        XCTAssertTrue(ActivityCenter.questionMayTakeSlotBack(asking: true, questionCardUp: true))
        XCTAssertFalse(ActivityCenter.questionMayTakeSlotBack(asking: true, questionCardUp: false))
        XCTAssertFalse(ActivityCenter.questionMayTakeSlotBack(asking: false, questionCardUp: true))
    }

    /// Another card leaving the forced slot while a question was up let what had queued behind it
    /// up at once; a main-queue turn later the question took the slot back, and the alert went
    /// down again, back into the queue with a second tap — a banner that blinked on and off.
    func testAnAlertBehindAnotherCardDoesNotBlinkUpBeforeTheQuestionTakesTheIslandBack() throws {
        let folder = "/tmp/notchctl-ask-test.\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        defer {
            IslandAsk.shared.resetForTesting()
            center.resetForTesting()
            try? FileManager.default.removeItem(atPath: folder)
        }
        let reply = (folder + "/answer").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        LiveActivityAPI.shared.handle(URL(string: "notchisland://ask?title=Deploy%3F&yes=Deploy&no=Wait&timeout=30&reply=\(reply)")!)
        XCTAssertTrue(IslandAsk.shared.isAsking)
        center.upsert(custom("api-x"))
        center.forceExpanded(id: "api-x", for: 0.2)
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        XCTAssertEqual(center.pendingAlerts.map(\.activity.id), ["download-done"], "waiting behind the other card")
        var shown: [String] = []
        let watch = center.$alert.sink { if let id = $0?.id { shown.append(id) } }
        settle(0.6)
        watch.cancel()
        XCTAssertEqual(center.forcedExpandedID, IslandAsk.activityID, "the question has the island again")
        XCTAssertFalse(shown.contains("download-done"), "never put up only to be taken straight down")
        XCTAssertEqual(center.pendingAlerts.map(\.activity.id), ["download-done"], "still waiting, now behind the question")
    }

    // MARK: - Only what changed is news

    private func volumeHUD(_ level: Double, muted: Bool = false) -> IslandActivity {
        IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: level, isMuted: muted)),
                       priority: 85)
    }

    func testAReportTheSameAsTheAlertUpChangesNothing() {
        let up = volumeHUD(1)
        var again = volumeHUD(1)
        again.startedAt = up.startedAt.addingTimeInterval(3)
        XCTAssertFalse(ActivityCenter.alertChanges(from: up, to: again),
                       "made a moment later, and the same in every other way")
        XCTAssertTrue(ActivityCenter.alertChanges(from: up, to: volumeHUD(0.5)), "a level the bar is not at")
        XCTAssertTrue(ActivityCenter.alertChanges(from: up, to: volumeHUD(1, muted: true)))
        XCTAssertTrue(ActivityCenter.alertChanges(from: nil, to: up), "nothing was up")
        XCTAssertTrue(ActivityCenter.alertChanges(from: custom("copied"), to: up), "another alert was")
    }

    /// The volume key pressed again at the top of the bar sends the same HUD, and every view
    /// that watches the centre was drawn again for it.
    func testTheSameReportAgainDoesNotRedrawTheIsland() {
        center.showAlert(volumeHUD(1), duration: 5, haptic: false)
        var published = 0
        let watching = center.objectWillChange.sink { _ in published += 1 }
        center.showAlert(volumeHUD(1), duration: 5, haptic: false)
        XCTAssertEqual(published, 0, "nothing new to draw")
        XCTAssertEqual(center.alert?.id, "hud", "and it is still up")
        center.showAlert(volumeHUD(0.9), duration: 5, haptic: false)
        XCTAssertEqual(published, 1, "a level that moved is drawn")
        watching.cancel()
        center.dismissAlert()
    }

    func testTheHUDsLevelIsDrawnOverTheHUDItBelongsTo() {
        let half = LevelHUD(kind: .volume, level: 0.5)
        var quarter = half
        quarter.level = 0.25
        XCTAssertTrue(HUDLevel.sameShape(half, quarter))
        XCTAssertEqual(HUDLevel.shown(half, live: quarter), quarter, "the same HUD, at the level it has moved to")
        var muted = quarter
        muted.isMuted = true
        XCTAssertFalse(HUDLevel.sameShape(half, muted))
        XCTAssertEqual(HUDLevel.shown(half, live: muted), half, "a view handed another HUD draws its own to the end")
        XCTAssertEqual(HUDLevel.shown(half, live: LevelHUD(kind: .brightness, level: 0.25)), half)
        var elsewhere = quarter
        elsewhere.device = "AirPods Pro"
        XCTAssertEqual(HUDLevel.shown(half, live: elsewhere), half, "nor another output's")
        XCTAssertEqual(HUDLevel.shown(half, live: nil), half)
    }

    func testTheCentreHandsOnTheLevelOfEveryHUDItPutsUp() {
        center.showAlert(volumeHUD(0.5), duration: 5, haptic: false)
        XCTAssertEqual(center.hudLevel.state?.level, 0.5)
        var published = 0
        let watching = center.hudLevel.objectWillChange.sink { _ in published += 1 }
        center.showAlert(volumeHUD(0.5), duration: 5, haptic: false)
        XCTAssertEqual(published, 0, "the same level again is not news")
        center.showAlert(volumeHUD(0.75), duration: 5, haptic: false)
        XCTAssertEqual(published, 1)
        XCTAssertEqual(center.hudLevel.state?.level, 0.75)
        center.showAlert(custom("copied"), duration: 5, haptic: false)
        XCTAssertEqual(published, 1, "an alert that is not a HUD leaves the level where it was")
        watching.cancel()
        center.dismissAlert()
        center.resetForTesting()
        XCTAssertNil(center.hudLevel.state)
    }
}
