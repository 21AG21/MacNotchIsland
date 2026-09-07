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

    private func custom(_ id: String, priority: Int = 70, title: String = "X") -> IslandActivity {
        IslandActivity(id: id, kind: .custom, content: .custom(CustomActivity(title: title)), priority: priority)
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
}
