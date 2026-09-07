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
        p.shelfEnabled = true
        p.hoverDelay = 0.01
    }

    private func custom(_ id: String, priority: Int = 70, title: String = "X", kind: ActivityKind = .custom) -> IslandActivity {
        IslandActivity(id: id, kind: kind, content: .custom(CustomActivity(title: title)), priority: priority)
    }

    func testIdleByDefault() {
        XCTAssertEqual(center.presentation, .idle)
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
        guard case .expanded(let shown) = center.presentation else { return XCTFail("expected expanded") }
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
        guard case .expanded(let a) = center.presentation else { return XCTFail("expected expanded on hover") }
        XCTAssertEqual(a.id, "a")

        center.end(id: "a")
        XCTAssertEqual(center.presentation, .home, "hovering with nothing live opens Home")

        center.setHovering(false)
        let exp2 = expectation(description: "hover cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exp2.fulfill() }
        wait(for: [exp2], timeout: 3)
        XCTAssertEqual(center.presentation, .idle)
    }

    func testDragTargetShowsShelf() {
        center.upsert(custom("a"))
        center.setDragTargeted(true)
        XCTAssertEqual(center.presentation, .shelf)
        center.setDragTargeted(false)
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
        guard case .expanded(let a) = center.presentation else { return XCTFail("expected forced expanded") }
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

    func testClickOpensAndClosesWithoutAnyHover() {
        Preferences.shared.hoverToExpand = false
        Preferences.shared.expandOnIdleHover = false
        center.upsert(IslandActivity(id: "timer", kind: .timer,
                                     content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 90))
        guard case .compact = center.presentation else { return XCTFail("compact at rest") }
        center.tap()
        guard case .expanded(let a) = center.presentation else { return XCTFail("a click opens the activity") }
        XCTAssertEqual(a.id, "timer")
        XCTAssertTrue(center.isOpen)
        center.tap()
        guard case .compact = center.presentation else { return XCTFail("a second click closes it") }
        XCTAssertFalse(center.isOpen)

        center.end(id: "timer")
        center.tap()
        XCTAssertEqual(center.presentation, .home, "clicking the empty island opens Home")
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

    func testKeyboardRingCyclesActivitiesThenHomeTabsAndWraps() {
        Preferences.shared.shelfEnabled = false
        Preferences.shared.clipboardEnabled = false
        Preferences.shared.quickActionsEnabled = false
        Preferences.shared.mirrorEnabled = false
        Preferences.shared.statsEnabled = false
        Preferences.shared.weatherEnabled = false
        center.upsert(IslandActivity(id: "timer", kind: .timer,
                                     content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 90))
        XCTAssertEqual(center.keyboardRing, [.activity(id: "timer"), .home(tab: "music")])

        center.cycleView(forward: true)
        XCTAssertEqual(center.openView, .activity(id: "timer"))
        center.cycleView(forward: true)
        XCTAssertEqual(center.openView, .home(tab: "music"))
        XCTAssertEqual(center.presentation, .home)
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
        guard case .expanded = center.presentation else { return XCTFail("shortcut opens the main activity") }
        center.toggle()
        guard case .compact = center.presentation else { return XCTFail("shortcut closes it again") }
    }

    func testDismissedAlertDropsItsOpenView() {
        let alert = IslandActivity(id: "bt", kind: .bluetooth,
                                   content: .bluetooth(BluetoothState(name: "AirPods", address: "", symbol: "airpods", batteryLeft: 50)),
                                   priority: 85)
        center.showAlert(alert, duration: 5)
        center.tap()
        guard case .expanded = center.presentation else { return XCTFail("clicking an alert opens its large view") }
        center.dismissAlert()
        XCTAssertFalse(center.isOpen)
        XCTAssertEqual(center.presentation, .idle)
    }
}
