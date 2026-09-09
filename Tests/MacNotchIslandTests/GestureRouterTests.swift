import XCTest
@testable import MacNotchIsland

/// Exercises the pure gesture policy directly, without AppKit events, CoreAudio or a
/// trackpad. `GestureRouter.handle` is a thin shell around these rules.
final class GestureRouterTests: XCTestCase {
    private typealias Router = GestureRouter
    private typealias Action = GestureRouter.Action
    private typealias Context = GestureRouter.Context

    /// Comfortably past both swipe thresholds; negative is a swipe to the left.
    private let left: CGFloat = -80
    private let right: CGFloat = 80

    private func panel(_ index: Int, of count: Int = 4, scrolls: Bool = false) -> Context {
        .panel(index: index, count: count, scrolls: scrolls)
    }

    /// The volume change an action carries, or nil when it is not a volume action.
    private func volumeDelta(_ action: Action) -> Double? {
        if case .volume(let delta) = action { return delta }
        return nil
    }

    // MARK: - Horizontal swipes: the compact Now Playing pill skips tracks

    func testSwipeLeftSkipsToNextTrackWhenCompact() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .compactNowPlaying), Action.nextTrack)
    }

    func testSwipeRightGoesToPreviousTrackWhenCompact() {
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: .compactNowPlaying), Action.previousTrack)
    }

    func testShortSwipeDoesNothing() {
        XCTAssertEqual(Router.decide(dx: -Router.swipeThreshold, dy: 0, context: .compactNowPlaying), Action.none)
        XCTAssertEqual(Router.decide(dx: 12, dy: 0, context: .compactNowPlaying), Action.none)
    }

    func testSwipeIsIgnoredForOtherCompactStatesAndCards() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .idle), Action.none)
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .otherCompact), Action.none)
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: .card), Action.none)
    }

    func testSwipeIsIgnoredOnTheShelfSoTheStripCanScroll() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .shelf), Action.none)
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: .shelf), Action.none)
    }

    // MARK: - Horizontal swipes: the panel steps through the ring

    func testSwipeLeftStepsToTheNextViewOfThePanel() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: panel(0)), Action.stepView(forward: true))
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: panel(2)), Action.stepView(forward: true))
    }

    func testSwipeRightStepsBack() {
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: panel(1)), Action.stepView(forward: false))
    }

    func testTheRingDoesNotWrapUnderASwipe() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: panel(3)), Action.none, "no view after the last")
        XCTAssertEqual(Router.decide(dx: right, dy: 0, context: panel(0)), Action.none, "no view before the first")
    }

    func testAViewStepAsksForALongerSwipeThanATrackSkip() {
        XCTAssertEqual(Router.decide(dx: -(Router.viewSwipeThreshold - 5), dy: 0, context: panel(0)), Action.none)
        XCTAssertEqual(Router.decide(dx: -(Router.viewSwipeThreshold + 5), dy: 0, context: panel(0)), Action.stepView(forward: true))
        XCTAssertEqual(Router.decide(dx: -(Router.swipeThreshold + 5), dy: 0, context: .compactNowPlaying), Action.nextTrack)
    }

    func testASingleViewHasNothingToStepTo() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: panel(0, of: 1)), Action.none)
    }

    func testAScrollingSectionStillStepsSideways() {
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: panel(0, scrolls: true)), Action.stepView(forward: true))
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

    func testVolumeWorksWhileCompactOnACardAndOnASectionThatDoesNotScroll() {
        for context in [Context.idle, .compactNowPlaying, .otherCompact, .card, panel(0)] {
            XCTAssertNotNil(volumeDelta(Router.decide(dx: 0, dy: -20, context: context)),
                            "expected a volume change for \(context)")
        }
    }

    func testVolumeIsLeftAloneWhereContentScrolls() {
        XCTAssertEqual(Router.decide(dx: 0, dy: -60, context: panel(1, scrolls: true)), Action.none)
        XCTAssertEqual(Router.decide(dx: 0, dy: -60, context: .shelf), Action.none)
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
        XCTAssertTrue(Router.consumesHorizontalSwipes(panel(0)))
        XCTAssertFalse(Router.consumesHorizontalSwipes(panel(0, of: 1)))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.idle))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.otherCompact))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.card))
        XCTAssertFalse(Router.consumesHorizontalSwipes(.shelf))
    }

    func testConsumesVerticalScroll() {
        XCTAssertTrue(Router.consumesVerticalScroll(.idle))
        XCTAssertTrue(Router.consumesVerticalScroll(.compactNowPlaying))
        XCTAssertTrue(Router.consumesVerticalScroll(.otherCompact))
        XCTAssertTrue(Router.consumesVerticalScroll(.card))
        XCTAssertTrue(Router.consumesVerticalScroll(panel(0)))
        XCTAssertFalse(Router.consumesVerticalScroll(panel(0, scrolls: true)))
        XCTAssertFalse(Router.consumesVerticalScroll(.shelf))
    }

    // MARK: - Sections

    func testTheSectionListIsOneListEverywhere() {
        let prefs = Preferences.shared
        let saved = (prefs.shelfEnabled, prefs.clipboardEnabled, prefs.quickActionsEnabled, prefs.statsEnabled, prefs.notesEnabled, prefs.calendarEnabled)
        defer {
            (prefs.shelfEnabled, prefs.clipboardEnabled, prefs.quickActionsEnabled, prefs.statsEnabled, prefs.notesEnabled, prefs.calendarEnabled) = saved
        }
        prefs.shelfEnabled = false
        prefs.clipboardEnabled = true
        XCTAssertEqual(HomeSection.resolve("shelf", prefs: prefs), .clipboard, "a section that is off resolves to the nearest one that is on")
        XCTAssertEqual(HomeSection.resolve("nonsense", prefs: prefs), .home)
        XCTAssertEqual(HomeSection.available(prefs).first, .home, "the grid is the front door and has no switch")
        XCTAssertTrue(HomeSection.available(prefs).contains(.music), "and Now Playing can never be switched off")
        XCTAssertEqual(HomeSection.allCases.map(\.rawValue).first, HomeSection.fallback.rawValue)
        XCTAssertTrue(GestureRouter.scrollingSections.contains(.clipboard))
    }

    // MARK: - Option turns the scroll into the brightness

    func testOptionScrollMovesTheBrightnessInstead() {
        let up = GestureRouter.decide(dx: 0, dy: -40, context: .idle, wantsBrightness: true)
        guard case .brightness(let delta) = up else { return XCTFail("expected brightness, got \(up)") }
        XCTAssertGreaterThan(delta, 0, "scrolling up brightens, the way it raises the volume")

        let down = GestureRouter.decide(dx: 0, dy: 40, context: .idle, wantsBrightness: true)
        guard case .brightness(let dim) = down else { return XCTFail("expected brightness, got \(down)") }
        XCTAssertLessThan(dim, 0)
    }

    func testTheScrollIsStillTheVolumeWithoutOption() {
        guard case .volume = GestureRouter.decide(dx: 0, dy: -40, context: .idle) else {
            return XCTFail("a bare scroll is the volume")
        }
    }

    func testBothTravelTheSameDistancePerPoint() {
        let volume = GestureRouter.decide(dx: 0, dy: -100, context: .idle)
        let brightness = GestureRouter.decide(dx: 0, dy: -100, context: .idle, wantsBrightness: true)
        guard case .volume(let v) = volume, case .brightness(let b) = brightness else {
            return XCTFail("expected one of each")
        }
        XCTAssertEqual(v, b, accuracy: 0.0001, "one scroll, two things it can move, one feel")
    }

    func testASectionThatScrollsKeepsItsScrollWhicheverKeyIsHeld() {
        let list = GestureRouter.Context.panel(index: 0, count: 4, scrolls: true)
        XCTAssertEqual(GestureRouter.decide(dx: 0, dy: -40, context: list, wantsBrightness: true), .none)
        XCTAssertEqual(GestureRouter.decide(dx: 0, dy: -40, context: list), .none)
    }
}
