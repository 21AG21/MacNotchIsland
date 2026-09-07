import XCTest
@testable import MacNotchIsland

/// Exercises the pure gesture policy directly, without AppKit events, CoreAudio or a
/// trackpad. `GestureRouter.handle` is a thin shell around these rules.
final class GestureRouterTests: XCTestCase {
    private typealias Router = GestureRouter
    private typealias Action = GestureRouter.Action
    private typealias Context = GestureRouter.Context

    private let allTabs = ["music", "shelf", "clipboard", "actions", "mirror", "stats", "weather"]

    /// Comfortably past the swipe threshold; negative is a swipe to the left.
    private let left: CGFloat = -80
    private let right: CGFloat = 80

    /// The volume change an action carries, or nil when it is not a volume action.
    private func volumeDelta(_ action: Action) -> Double? {
        if case .volume(let delta) = action { return delta }
        return nil
    }

    // MARK: - Horizontal swipes: Now Playing

    func testSwipeLeftSkipsToNextTrackWhenCompact() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .compactNowPlaying), Action.nextTrack)
    }

    func testSwipeRightGoesToPreviousTrackWhenCompact() {
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: .compactNowPlaying), Action.previousTrack)
    }

    func testSwipesWorkInTheExpandedPlayerToo() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .expandedNowPlaying), Action.nextTrack)
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: .expandedNowPlaying), Action.previousTrack)
    }

    func testShortSwipeDoesNothing() {
        XCTAssertEqual(Router.decide(dx: -Router.swipeThreshold, dy: 0, context: .compactNowPlaying), Action.none)
        XCTAssertEqual(Router.decide(dx: 12, dy: 0, context: .compactNowPlaying), Action.none)
    }

    func testSwipeIsIgnoredForOtherActivities() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .idle), Action.none)
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .otherCompact), Action.none)
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: .otherExpanded), Action.none)
    }

    func testSwipeIsIgnoredOnTheShelfSoTheStripCanScroll() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .shelf), Action.none)
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: .shelf), Action.none)
    }

    // MARK: - Horizontal swipes: Home tabs

    func testSwipeLeftMovesToTheNextHomeTab() {
        let context = Context.home(tab: "music", available: allTabs)
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: context), Action.selectTab("shelf"))
    }

    func testSwipeRightMovesToThePreviousHomeTab() {
        let context = Context.home(tab: "clipboard", available: allTabs)
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: context), Action.selectTab("shelf"))
    }

    func testHomeTabsWrapAround() {
        let last = allTabs.last!
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .home(tab: last, available: allTabs)),
                       Action.selectTab("music"))
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: .home(tab: "music", available: allTabs)),
                       Action.selectTab(last))
    }

    func testHomeTabsSkipDisabledFeatures() {
        let context = Context.home(tab: "music", available: ["music", "actions"])
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: context), Action.selectTab("actions"))
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: context), Action.selectTab("actions"))
    }

    func testStoredTabThatIsNoLongerAvailableFallsBackToMusic() {
        // The shelf was switched off while it was the selected tab; Home shows Music, so a
        // swipe moves on from Music.
        let context = Context.home(tab: "shelf", available: ["music", "clipboard"])
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: context), Action.selectTab("clipboard"))
    }

    func testShelfTabKeepsItsHorizontalScrolling() {
        let context = Context.home(tab: "shelf", available: allTabs)
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: context), Action.none)
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: context), Action.none)
    }

    func testASingleAvailableTabHasNothingToCycle() {
        let context = Context.home(tab: "music", available: ["music"])
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: context), Action.none)
    }

    // MARK: - Vertical scrolling

    func testScrollingUpRaisesTheVolume() {
        // AppKit reports an upward swipe as a negative delta.
        let delta = volumeDelta(Router.decide(dx: 0, dy: -100, context: .idle))
        XCTAssertNotNil(delta)
        XCTAssertEqual(delta ?? 0, 100 * Router.volumeStep, accuracy: 1e-9)
    }

    func testScrollingDownLowersTheVolume() {
        let delta = volumeDelta(Router.decide(dx: 0, dy: 100, context: .idle))
        XCTAssertNotNil(delta)
        XCTAssertEqual(delta ?? 0, -100 * Router.volumeStep, accuracy: 1e-9)
    }

    func testVolumeScalesWithTheDistanceScrolled() {
        let small = volumeDelta(Router.decide(dx: 0, dy: -10, context: .compactNowPlaying)) ?? 0
        let large = volumeDelta(Router.decide(dx: 0, dy: -40, context: .compactNowPlaying)) ?? 0
        XCTAssertEqual(large, small * 4, accuracy: 1e-9)
        XCTAssertGreaterThan(small, 0)
    }

    func testVolumeWorksWhileCompactAndInTheExpandedPlayer() {
        for context in [Context.idle, .compactNowPlaying, .expandedNowPlaying, .otherCompact] {
            XCTAssertNotNil(volumeDelta(Router.decide(dx: 0, dy: -20, context: context)),
                            "expected a volume change for \(context)")
        }
    }

    func testVolumeIsLeftAloneWhereContentScrolls() {
        XCTAssertEqual(Router.decide(dx: 0, dy: -60, context: .home(tab: "clipboard", available: allTabs)), Action.none)
        XCTAssertEqual(Router.decide(dx: 0, dy: 60, context: .home(tab: "music", available: allTabs)), Action.none)
        XCTAssertEqual(Router.decide(dx: 0, dy: -60, context: .shelf), Action.none)
        XCTAssertEqual(Router.decide(dx: 0, dy: -60, context: .otherExpanded), Action.none)
    }

    func testNoMovementDoesNothing() {
        XCTAssertEqual(Router.decide(dx: 0, dy: 0, context: .idle), Action.none)
        XCTAssertEqual(Router.decide(dx: 0, dy: 0, context: .compactNowPlaying), Action.none)
    }

    // MARK: - Mixed axes

    func testAMostlyVerticalGestureNeverSkipsTracks() {
        let action = Router.decide(dx: -100, dy: -260, context: .compactNowPlaying)
        XCTAssertNotNil(volumeDelta(action))
    }

    func testAMostlyHorizontalGestureNeverTouchesTheVolume() {
        XCTAssertEqual(Router.decide(dx: -200, dy: -30, context: .compactNowPlaying), Action.nextTrack)
    }

    func testAHorizontalGestureWithNothingToSwipeStillLeavesTheVolumeAlone() {
        // Idle has nothing to swipe between, so a purely horizontal gesture is handed back to
        // SwiftUI; any vertical component still counts as a volume change.
        XCTAssertEqual(Router.decide(dx: -200, dy: 0, context: .idle), Action.none)
        XCTAssertNotNil(volumeDelta(Router.decide(dx: -200, dy: -30, context: .idle)))
    }

    // MARK: - Context predicates

    func testConsumesHorizontalSwipes() {
        XCTAssertTrue(Router.consumesHorizontalSwipes(.compactNowPlaying))
        XCTAssertTrue(Router.consumesHorizontalSwipes(.expandedNowPlaying))
        XCTAssertTrue(Router.consumesHorizontalSwipes(.home(tab: "music", available: allTabs)))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.home(tab: "shelf", available: allTabs)))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.home(tab: "music", available: ["music"])))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.idle))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.otherCompact))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.otherExpanded))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.shelf))
    }

    func testConsumesVerticalScroll() {
        XCTAssertTrue(Router.consumesVerticalScroll(.idle))
        XCTAssertTrue(Router.consumesVerticalScroll(.compactNowPlaying))
        XCTAssertTrue(Router.consumesVerticalScroll(.expandedNowPlaying))
        XCTAssertTrue(Router.consumesVerticalScroll(.otherCompact))
        XCTAssertFalse(Router.consumesVerticalScroll(.otherExpanded))
        XCTAssertFalse(Router.consumesVerticalScroll(.home(tab: "music", available: allTabs)))
        XCTAssertFalse(Router.consumesVerticalScroll(.shelf))
    }

    func testEffectiveTab() {
        XCTAssertEqual(Router.effectiveTab("clipboard", available: allTabs), "clipboard")
        XCTAssertEqual(Router.effectiveTab("clipboard", available: ["music", "shelf"]), "music")
        XCTAssertEqual(Router.effectiveTab("music", available: []), "music")
    }

    func testHomeTabOrderMatchesTheTabBar() {
        XCTAssertEqual(Router.homeTabOrder, allTabs)
        XCTAssertEqual(Router.homeTabOrder.first, Router.defaultHomeTab)
    }
}
