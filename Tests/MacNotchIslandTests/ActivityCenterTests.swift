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

}
