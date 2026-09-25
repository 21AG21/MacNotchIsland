import XCTest
@testable import MacNotchIsland

/// The vertical half of the gesture policy with "Open and close" in it: which way a bare
/// scroll goes in each mode, in every place the island can be, and how a scroll on a timer's
/// pill tells a nudge from a swipe. Pure rules only, like `GestureRouterTests`: no trackpad,
/// no CoreAudio, no panel.
final class VerticalSwipeTests: XCTestCase {
    private typealias Router = GestureRouter
    private typealias Action = GestureRouter.Action
    private typealias Context = GestureRouter.Context

    /// Comfortably past the swipe's threshold at the middle sensitivity. Positive is the
    /// fingers going down, as AppKit reports it with natural scrolling.
    private let down: CGFloat = 80
    private let up: CGFloat = -80

    /// What an action is, without the figures a volume change carries.
    private enum Kind: Equatable {
        case volumeUp, volumeDown, open, close, nudge(Int), nothing, other
    }

    private func kind(_ action: Action) -> Kind {
        switch action {
        case .volume(let delta): return delta > 0 ? .volumeUp : .volumeDown
        case .openPanel: return .open
        case .closePanel: return .close
        case .nudgeTimer(let steps): return .nudge(steps)
        case .none: return .nothing
        default: return .other
        }
    }

    private func decide(_ dy: CGFloat, _ context: Context, _ mode: Router.VerticalSwipe,
                        sensitivity: Double = 1) -> Kind {
        kind(Router.decide(dx: 0, dy: dy, context: context, verticalSwipe: mode, sensitivity: sensitivity))
    }

    // MARK: - Every place the island can be, in both modes

    /// Each context the island can be in, named for the failure message.
    private var contexts: [(name: String, context: Context)] {
        [("idle", .idle),
         ("the Now Playing pill", .compactNowPlaying),
         ("a timer's pill", .compactTimer),
         ("another pill", .otherCompact),
         ("a card", .card),
         ("a pinned panel", .panel(index: 0, count: 4, scrolls: false, pinned: true)),
         ("a peeked panel", .panel(index: 0, count: 4, scrolls: false, pinned: false)),
         ("a section that scrolls", .panel(index: 1, count: 4, scrolls: true, pinned: true)),
         ("the shelf mid-drag", .shelf)]
    }

    /// 80 points on a timer is three whole minutes of 24.
    private var timerSteps: Int { Int(down / Router.timerStepDistance) }

    func testVolumeModeIsTheVolumeEverywhereItWasAndMinutesOnATimer() {
        let expectDown: [String: Kind] = [
            "idle": .volumeDown, "the Now Playing pill": .volumeDown, "a timer's pill": .nudge(-timerSteps),
            "another pill": .volumeDown, "a card": .volumeDown, "a pinned panel": .volumeDown,
            "a peeked panel": .volumeDown, "a section that scrolls": .nothing, "the shelf mid-drag": .nothing,
        ]
        let expectUp: [String: Kind] = [
            "idle": .volumeUp, "the Now Playing pill": .volumeUp, "a timer's pill": .nudge(timerSteps),
            "another pill": .volumeUp, "a card": .volumeUp, "a pinned panel": .volumeUp,
            "a peeked panel": .volumeUp, "a section that scrolls": .nothing, "the shelf mid-drag": .nothing,
        ]
        for (name, context) in contexts {
            XCTAssertEqual(decide(down, context, .volume), expectDown[name], "down on \(name)")
            XCTAssertEqual(decide(up, context, .volume), expectUp[name], "up on \(name)")
        }
    }

    func testOpenAndCloseOpensTheClosedIslandAndClosesThePanel() {
        let expectDown: [String: Kind] = [
            "idle": .open, "the Now Playing pill": .open, "a timer's pill": .open,
            "another pill": .open, "a card": .open, "a pinned panel": .nothing,
            "a peeked panel": .open, "a section that scrolls": .nothing, "the shelf mid-drag": .nothing,
        ]
        let expectUp: [String: Kind] = [
            "idle": .nothing, "the Now Playing pill": .nothing, "a timer's pill": .nudge(timerSteps),
            "another pill": .nothing, "a card": .nothing, "a pinned panel": .close,
            "a peeked panel": .close, "a section that scrolls": .nothing, "the shelf mid-drag": .nothing,
        ]
        for (name, context) in contexts {
            XCTAssertEqual(decide(down, context, .openClose), expectDown[name], "down on \(name)")
            XCTAssertEqual(decide(up, context, .openClose), expectUp[name], "up on \(name)")
        }
    }

    func testWhereTheIslandKeepsTheScrollDoesNotDependOnTheMode() {
        for (name, context) in contexts {
            let kept = Router.consumesVerticalScroll(context)
            switch context {
            case .shelf, .panel(_, _, true, _):
                XCTAssertFalse(kept, "\(name) keeps its own scroll")
            default:
                XCTAssertTrue(kept, "the island keeps a scroll on \(name)")
            }
        }
    }

    func testOpenAndCloseMovesNoVolume() {
        for (name, context) in contexts {
            for dy: CGFloat in [down, up, 10, -10] {
                let action = decide(dy, context, .openClose)
                XCTAssertNotEqual(action, .volumeUp, "\(name), \(dy)")
                XCTAssertNotEqual(action, .volumeDown, "\(name), \(dy)")
            }
        }
    }

    func testASwipeShortOfTheThresholdDoesNothingOnTheClosedIsland() {
        let short = Router.openCloseDistance - 5
        for context in [Context.idle, .compactNowPlaying, .otherCompact, .card] {
            XCTAssertEqual(decide(short, context, .openClose), .nothing, "\(context)")
        }
        XCTAssertEqual(decide(-short, .panel(index: 0, count: 4, scrolls: false), .openClose), .nothing)
        XCTAssertEqual(decide(Router.openCloseDistance, .idle, .openClose), .open, "the threshold itself is far enough")
    }

    func testSidewaysSwipesKeepTheirMeaningInOpenAndClose() {
        let left: CGFloat = -80
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .compactNowPlaying, verticalSwipe: .openClose), .nextTrack)
        XCTAssertEqual(Router.decide(dx: left, dy: 0, context: .panel(index: 0, count: 4, scrolls: false),
                                     verticalSwipe: .openClose), .stepView(forward: true))
        XCTAssertEqual(Router.decide(dx: left, dy: -10, context: .panel(index: 0, count: 4, scrolls: false, pinned: false),
                                     verticalSwipe: .openClose), .stepView(forward: true))
    }

    func testAMostlySidewaysGestureNeverOpensThePanel() {
        // Past the vertical threshold, but further still sideways: a track skip.
        XCTAssertEqual(Router.decide(dx: -200, dy: 60, context: .compactNowPlaying, verticalSwipe: .openClose), .nextTrack)
    }

    func testOptionAndControlStillNameTheirLevelsInOpenAndClose() {
        let brightness = Router.decide(dx: 0, dy: up, context: .idle, wantsBrightness: true, verticalSwipe: .openClose)
        guard case .brightness(let b) = brightness else { return XCTFail("Option is the brightness, got \(brightness)") }
        XCTAssertGreaterThan(b, 0)
        let keyboard = Router.decide(dx: 0, dy: down, context: .idle, wantsKeyboard: true, verticalSwipe: .openClose)
        guard case .keyboard(let k) = keyboard else { return XCTFail("Control is the backlight, got \(keyboard)") }
        XCTAssertLessThan(k, 0)
        // Both at once mean neither, and the scroll is whatever a bare one is: here, a swipe.
        XCTAssertEqual(Router.decide(dx: 0, dy: down, context: .idle, wantsBrightness: true, wantsKeyboard: true,
                                     verticalSwipe: .openClose), .openPanel)
    }

    func testTheSwipeIsMeasuredOnTheWholeGestureAndTheVolumeOnWhatIsLeft() {
        // One small event at the end of a long gesture: the gesture has come far enough.
        XCTAssertEqual(Router.decide(dx: 0, dy: 4, context: .idle, verticalSwipe: .openClose, travel: 60), .openPanel)
        XCTAssertEqual(Router.decide(dx: 0, dy: 4, context: .idle, verticalSwipe: .openClose, travel: 20), Action.none)
        // The volume moves by the part not applied yet, whatever the gesture's total.
        XCTAssertEqual(Router.decide(dx: 0, dy: -4, context: .idle, travel: -400), .volume(delta: 4 * Router.volumeStep))
    }

    // MARK: - Sensitivity

    func testSensitivityScalesTheDistance() {
        XCTAssertEqual(Router.openCloseThreshold(sensitivity: 1), Router.openCloseDistance)
        XCTAssertEqual(Router.openCloseThreshold(sensitivity: 2), Router.openCloseDistance / 2, accuracy: 1e-9)
        XCTAssertEqual(Router.openCloseThreshold(sensitivity: 0.5), Router.openCloseDistance * 2, accuracy: 1e-9)
    }

    func testSensitivityIsHeldToTheSlidersRange() {
        XCTAssertEqual(Router.openCloseThreshold(sensitivity: 10), Router.openCloseThreshold(sensitivity: 2))
        XCTAssertEqual(Router.openCloseThreshold(sensitivity: 0), Router.openCloseThreshold(sensitivity: 0.5))
        XCTAssertEqual(Router.openCloseThreshold(sensitivity: -3), Router.openCloseThreshold(sensitivity: 0.5))
    }

    func testAMoreSensitiveSwipeOpensSooner() {
        XCTAssertEqual(decide(30, .idle, .openClose, sensitivity: 1), .nothing)
        XCTAssertEqual(decide(30, .idle, .openClose, sensitivity: 2), .open)
        XCTAssertEqual(decide(80, .idle, .openClose, sensitivity: 0.5), .nothing, "half as sensitive is twice as far")
        XCTAssertEqual(decide(110, .idle, .openClose, sensitivity: 0.5), .open)
        XCTAssertEqual(decide(-30, .panel(index: 0, count: 2, scrolls: false), .openClose, sensitivity: 2), .close)
    }

    func testTheSensitivityMeansNothingToTheVolume() {
        XCTAssertEqual(Router.decide(dx: 0, dy: -40, context: .idle, sensitivity: 2),
                       Router.decide(dx: 0, dy: -40, context: .idle, sensitivity: 0.5))
    }

    // MARK: - The stored choice

    func testTheStoredChoiceReadsBack() {
        XCTAssertEqual(Router.VerticalSwipe(preference: "volume"), .volume)
        XCTAssertEqual(Router.VerticalSwipe(preference: "openClose"), .openClose)
        XCTAssertEqual(Router.VerticalSwipe(preference: ""), .volume, "nothing stored is the volume")
        XCTAssertEqual(Router.VerticalSwipe(preference: "sideways"), .volume, "and so is anything unknown")
    }

    // MARK: - A timer's pill: a small scroll nudges, a big swipe opens

    func testASmallScrollUpGivesATimerAnotherMinute() {
        XCTAssertEqual(decide(-30, .compactTimer, .volume), .nudge(1))
        XCTAssertEqual(decide(-30, .compactTimer, .openClose), .nudge(1))
    }

    func testAScrollShorterThanAStepMovesNothing() {
        XCTAssertEqual(decide(-(Router.timerStepDistance - 1), .compactTimer, .volume), .nothing)
        XCTAssertEqual(decide(Router.timerStepDistance - 1, .compactTimer, .volume), .nothing)
        XCTAssertEqual(decide(0, .compactTimer, .volume), .nothing)
    }

    func testTheStepsCountTheWholeGesture() {
        // A step for every stretch of `timerStepDistance`, counted toward zero.
        XCTAssertEqual(Router.timerSteps(travel: -Router.timerStepDistance), 1)
        XCTAssertEqual(Router.timerSteps(travel: -Router.timerStepDistance * 4.5), 4)
        XCTAssertEqual(Router.timerSteps(travel: Router.timerStepDistance * 2), -2, "down asks for less")
        XCTAssertEqual(Router.timerSteps(travel: .infinity), 0)
        XCTAssertEqual(Router.timerSteps(travel: -1e12), 999, "bounded, never a trap")
        XCTAssertEqual(Router.decide(dx: 0, dy: -2, context: .compactTimer, travel: -100), .nudgeTimer(steps: 4))
    }

    func testAScrollDownOnATimerIsMinutesInVolumeModeAndASwipeInOpenAndClose() {
        XCTAssertEqual(decide(30, .compactTimer, .volume), .nudge(-1))
        XCTAssertEqual(decide(30, .compactTimer, .openClose), .nudge(-1), "short of the threshold: a nudge")
        XCTAssertEqual(decide(Router.openCloseDistance, .compactTimer, .openClose), .open, "far enough: a swipe")
        XCTAssertEqual(decide(200, .compactTimer, .volume), .nudge(-8), "the volume mode has no swipe to become")
    }

    func testTheSensitivityDecidesWhereANudgeBecomesASwipe() {
        XCTAssertEqual(decide(30, .compactTimer, .openClose, sensitivity: 1), .nudge(-1))
        XCTAssertEqual(decide(30, .compactTimer, .openClose, sensitivity: 2), .open)
    }

    func testAKeyHeldOnATimerStillNamesItsLevel() {
        let action = Router.decide(dx: 0, dy: -30, context: .compactTimer, wantsBrightness: true)
        guard case .brightness = action else { return XCTFail("Option on a timer is the brightness, got \(action)") }
    }

    func testATimersPillTakesNoSidewaysSwipe() {
        XCTAssertFalse(Router.consumesHorizontalSwipes(.compactTimer))
        XCTAssertEqual(Router.decide(dx: -80, dy: 0, context: .compactTimer), Action.none)
        XCTAssertTrue(Router.consumesVerticalScroll(.compactTimer))
    }

    func testAStepIsShorterThanTheSwipeAtEverySensitivity() {
        // A small scroll has to be able to nudge before a big one opens, even at the most
        // sensitive setting, where the two come closest.
        for sensitivity in [Router.sensitivityRange.lowerBound, 1, 1.5, Router.sensitivityRange.upperBound] {
            XCTAssertLessThan(Router.timerStepDistance, Router.openCloseThreshold(sensitivity: sensitivity),
                              "at \(sensitivity)")
        }
    }

    // MARK: - Minutes off, and minutes put back

    /// A timer with `remaining` to go, moved by the same rule the real one is.
    private func fakeTimer(_ remaining: TimeInterval) -> (move: Router.TimerNudge.Move, remaining: () -> TimeInterval) {
        var left = remaining
        let move: Router.TimerNudge.Move = { _, seconds in
            let change = IslandTimer.adjustment(seconds, remaining: left)
            left += change
            return change
        }
        return (move, { left })
    }

    func testAScrollDownTakesMinutesOffARunningTimer() {
        let timer = IslandTimer.shared
        timer.cancelAll()
        defer { timer.cancelAll() }
        timer.start(seconds: 600, label: "Tea")
        guard let id = timer.primary?.id else { return XCTFail("no timer") }
        XCTAssertEqual(Router.moveTimer(id: id, seconds: -2 * IslandTimer.addStep), -120, accuracy: 0.01,
                       "a scroll down is minutes off, not a scroll that does nothing")
        XCTAssertEqual(timer.entry(id: id)?.state.remaining(at: Date()) ?? 0, 480, accuracy: 1)
        XCTAssertEqual(Router.moveTimer(id: id, seconds: IslandTimer.addStep), 60, accuracy: 0.01)
        XCTAssertEqual(timer.entry(id: id)?.state.remaining(at: Date()) ?? 0, 540, accuracy: 1)
        // More than is left stops at the last second, and says how far it really went.
        let moved = Router.moveTimer(id: id, seconds: -20 * IslandTimer.addStep)
        XCTAssertEqual(moved, -539, accuracy: 1)
        XCTAssertEqual(timer.entry(id: id)?.state.remaining(at: Date()) ?? 0, IslandTimer.minimumRemaining, accuracy: 1)
        XCTAssertFalse(timer.entry(id: id)?.state.isFinished ?? true, "shortened, never rung on the spot")
        // A timer that has rung has nothing to move.
        timer.finishForTesting(id: id)
        XCTAssertEqual(Router.moveTimer(id: id, seconds: IslandTimer.addStep), 0)
        XCTAssertEqual(Router.moveTimer(id: id, seconds: -IslandTimer.addStep), 0)
        XCTAssertEqual(Router.moveTimer(id: "no-such-timer", seconds: IslandTimer.addStep), 0)
    }

    func testANudgeDownStopsAtTheLastSecondAndCountsOnlyWhatLanded() {
        let tea = fakeTimer(90)
        var nudge = Router.TimerNudge()
        XCTAssertTrue(nudge.nudge(id: "tea", toward: -1, move: tea.move))
        XCTAssertEqual(tea.remaining(), 30)
        XCTAssertTrue(nudge.nudge(id: "tea", toward: -2, move: tea.move), "what there is to take, is taken")
        XCTAssertEqual(tea.remaining(), IslandTimer.minimumRemaining)
        XCTAssertEqual(nudge.moved, -89, "not the two minutes asked for")
        XCTAssertFalse(nudge.nudge(id: "tea", toward: -3, move: tea.move), "nothing left to take")
        XCTAssertEqual(nudge.steps, -2, "a step that moved nothing is not counted")
        XCTAssertFalse(nudge.nudge(id: "coffee", toward: 1, move: tea.move), "a gesture belongs to the timer it moved")
    }

    func testASwipeThatNudgedATimerOnItsWayPutsTheMinutesBack() {
        // The fingers go down a timer's pill in "Open and close": past a step's distance first,
        // then past the swipe's. The router applies each event the way it does here.
        let tea = fakeTimer(300)
        var nudge = Router.TimerNudge()
        var opened = false
        for travel: CGFloat in [10, 30, 45, 60] {
            switch Router.decide(dx: 0, dy: 10, context: .compactTimer, verticalSwipe: .openClose, travel: travel) {
            case .nudgeTimer(let steps):
                _ = nudge.nudge(id: "tea", toward: steps, move: tea.move)
                if travel == 30 { XCTAssertEqual(tea.remaining(), 240, "a minute off on the way past") }
            case .openPanel:
                opened = true
                XCTAssertTrue(nudge.putBack(move: tea.move))
            default:
                break
            }
        }
        XCTAssertTrue(opened)
        XCTAssertEqual(tea.remaining(), 300, "the swipe was the whole gesture, and the timer is as it was")
        XCTAssertEqual(nudge, Router.TimerNudge(), "and nothing is left to put back twice")
        XCTAssertFalse(nudge.putBack(move: tea.move))
    }

    func testAPutBackUndoesExactlyWhatLandedEitherWay() {
        // Up two, down one: a minute on, and a minute is what goes back.
        let tea = fakeTimer(300)
        var nudge = Router.TimerNudge()
        XCTAssertTrue(nudge.nudge(id: "tea", toward: 2, move: tea.move))
        XCTAssertTrue(nudge.nudge(id: "tea", toward: 1, move: tea.move))
        XCTAssertEqual(tea.remaining(), 360)
        XCTAssertTrue(nudge.putBack(move: tea.move))
        XCTAssertEqual(tea.remaining(), 300)
        // Down past the floor: the seconds that really came off go back, not the minutes asked.
        let short = fakeTimer(90)
        var down = Router.TimerNudge()
        XCTAssertTrue(down.nudge(id: "tea", toward: -2, move: short.move))
        XCTAssertEqual(short.remaining(), IslandTimer.minimumRemaining)
        XCTAssertTrue(down.putBack(move: short.move))
        XCTAssertEqual(short.remaining(), 90)
        // And a gesture that came back to where it started has nothing to put back.
        var there = Router.TimerNudge()
        _ = there.nudge(id: "tea", toward: 1, move: tea.move)
        _ = there.nudge(id: "tea", toward: 0, move: tea.move)
        XCTAssertFalse(there.putBack(move: tea.move))
        XCTAssertEqual(tea.remaining(), 300)
    }
}

/// What a swipe down opens, and where: `ActivityCenter.openBySwipe`, which the router calls
/// once a swipe has gone far enough.
final class SwipeOpenTests: XCTestCase {
    private var center: ActivityCenter { ActivityCenter.shared }

    override func setUp() {
        super.setUp()
        center.resetForTesting()
        HomeSection.allCases.forEach { $0.setEnabled(true, in: Preferences.shared) }
    }

    override func tearDown() {
        center.resetForTesting()
        super.tearDown()
    }

    func testASwipeDownOnTheBareNotchOpensTheSectionLastShown() {
        XCTAssertTrue(center.openBySwipe(panel: "main"))
        XCTAssertEqual(center.presentation(for: "main"), .panel(.home(tab: ActivityCenter.currentHomeTab)))
    }

    func testASwipeOpensTheIslandItWasOnAndNoOther() {
        center.openBySwipe(panel: "screen-2")
        XCTAssertTrue(center.openHere("screen-2"))
        XCTAssertFalse(center.openHere("screen-1"), "the other display's island stays as it was")
    }

    func testASwipeOnATimersPillOpensItsCard() {
        let state = TimerState(label: "Tea", total: 300, endDate: Date().addingTimeInterval(300))
        center.upsert(IslandActivity(id: "swipe-timer", kind: .timer, content: .timer(state), priority: 90))
        XCTAssertTrue(center.openBySwipe(panel: "main"))
        XCTAssertEqual(center.openView, .activity(id: "swipe-timer"))
    }

    func testAPanelAlreadyOpenHereHasNothingMoreToOpen() {
        let music = IslandView.home(tab: HomeSection.music.rawValue)
        center.open(music, panel: "main")
        XCTAssertFalse(center.openBySwipe(panel: "main"))
        XCTAssertEqual(center.openView, music, "and what was open stays open")
    }

    func testNothingOpensWhileAFileIsHeldOverTheIsland() {
        center.setDragTargeted(true)
        XCTAssertEqual(center.presentation(for: "main"), .shelf)
        XCTAssertFalse(center.openBySwipe(panel: "main"))
        XCTAssertFalse(center.isOpen)
    }
}
