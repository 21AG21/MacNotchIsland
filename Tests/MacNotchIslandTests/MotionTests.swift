import SwiftUI
import XCTest
@testable import MacNotchIsland

/// The rules the island's motion vocabulary is built on. A curve cannot be looked at from a
/// test, but which curve was chosen can be, and choosing the wrong kind is the mistake that
/// makes an interface feel almost right: a spring on an opacity ripples, a symmetric press
/// lands late, an outline that bounces on the way back in wobbles.
final class MotionTests: XCTestCase {

    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                         notchWidth: 185, notchHeight: 33.5, hasPhysicalNotch: true)

    func testAPressIsNotSymmetric() {
        XCTAssertNotEqual(IslandMotion.press(down: true), IslandMotion.press(down: false),
                          "a press that eases in as slowly as it eases out answers late")
    }

    func testHoverAndFadeAreCurvesRatherThanSprings() {
        XCTAssertEqual(IslandMotion.hover, .easeOut(duration: 0.12))
        XCTAssertEqual(IslandMotion.fade, .easeInOut(duration: 0.18))
    }

    func testAMeterSweepsForAsLongAsItsValuesTakeToArrive() {
        XCTAssertEqual(IslandMotion.meter(cadence: 1), .linear(duration: 1))
        XCTAssertEqual(IslandMotion.meter(cadence: 0), .linear(duration: 0.05),
                       "never instant, and never a negative duration")
    }

    func testGrowingAndShrinkingAreNotTheSameCurve() {
        let compact = IslandLayout.make(presentation: .idle, geometry: geometry)
        let panel = IslandLayout.make(presentation: .panel(.home(tab: HomeSection.music.rawValue)), geometry: geometry)
        XCTAssertGreaterThan(panel.bodyWidth, compact.bodyWidth)
        XCTAssertEqual(IslandMotion.shape(from: compact, to: panel), IslandMotion.open)
        XCTAssertEqual(IslandMotion.shape(from: panel, to: compact), IslandMotion.close)
        XCTAssertNotEqual(IslandMotion.open, IslandMotion.close)
    }

    func testSteppingSidewaysOverridesBothOfThem() {
        let a = IslandLayout.make(presentation: .panel(.home(tab: HomeSection.music.rawValue)), geometry: geometry)
        let b = IslandLayout.make(presentation: .panel(.home(tab: HomeSection.shelf.rawValue)), geometry: geometry)
        // One panel width for every view, so the outline is not growing or shrinking at all;
        // it follows the content across instead.
        XCTAssertEqual(IslandMotion.shape(from: a, to: b, direction: 1), IslandMotion.navigate)
        XCTAssertEqual(IslandMotion.shape(from: a, to: b, direction: -1), IslandMotion.navigate)
    }

    /// The live answer comes from a cached watcher there is no way to set from a test, so
    /// the choice itself is exercised with the setting handed in. Without this the ternary
    /// could be inverted and every other test here would still pass.
    func testReduceMotionReplacesASpringWithAFadeOfItsOwnLength() {
        let spring = Animation.spring(duration: 0.44, bounce: 0.28)
        XCTAssertEqual(IslandMotion.moving(spring, still: 0.18, reduced: false), spring,
                       "with the setting off a spring stays a spring")
        XCTAssertEqual(IslandMotion.moving(spring, still: 0.18, reduced: true), .easeOut(duration: 0.18),
                       "and with it on it becomes a fade, not a shorter spring")
    }

    /// The swap a change of view gets, with the setting handed in. The blur cross-fade was
    /// Reduce Motion's answer, and it scales the content as it blurs.
    func testReduceMotionSwapsContentWithAPlainFade() {
        for direction in [-1, 0, 1] {
            XCTAssertEqual(IslandMotion.contentSwap(direction: direction, reduceMotion: true), .fade,
                           "nothing slides, blurs or scales, however the view changed (\(direction))")
        }
        XCTAssertEqual(IslandMotion.contentSwap(direction: 0, reduceMotion: false), .blurReplace)
        XCTAssertEqual(IslandMotion.contentSwap(direction: 1, reduceMotion: false), .push(offset: IslandMotion.slideDistance))
        XCTAssertEqual(IslandMotion.contentSwap(direction: -1, reduceMotion: false), .push(offset: -IslandMotion.slideDistance))
        // The transition itself takes the same setting, so a view can be handed either answer.
        _ = IslandMotion.contentTransition(direction: 1, reduceMotion: true)
    }

    func testTheSwitchersDiscTravelsOnlyWithoutReduceMotion() {
        XCTAssertTrue(IslandMotion.marksTravel(reduceMotion: false), "a mark that travels says which way you went")
        XCTAssertFalse(IslandMotion.marksTravel(reduceMotion: true), "and with less movement asked for, it fades across")
    }

    func testTheSpringsAreAllDifferentFromEachOther() throws {
        try XCTSkipIf(IslandMotion.reduceMotion, "this machine is already asking for less motion")
        XCTAssertNotEqual(IslandMotion.open, IslandMotion.navigate)
        XCTAssertNotEqual(IslandMotion.content, IslandMotion.control)
        XCTAssertNotEqual(IslandMotion.bubble, IslandMotion.open)
        // The eases are unaffected by the setting either way.
        XCTAssertEqual(IslandMotion.hover, .easeOut(duration: 0.12))
    }

    // MARK: - The user's hand on the springs

    /// The base numbers, held one by one. A multiplier at 1 can only reproduce what is here,
    /// so this is the half of "nothing changed" that the multiplier cannot vouch for.
    func testTheShippedNumbersAreThePhonesOwn() {
        typealias Given = IslandMotion.SpringParameters
        XCTAssertEqual(IslandMotion.Spring.open.base, Given(duration: 0.44, bounce: 0.28))
        XCTAssertEqual(IslandMotion.Spring.close.base, Given(duration: 0.32, bounce: 0))
        XCTAssertEqual(IslandMotion.Spring.navigate.base, Given(duration: 0.34, bounce: 0.06))
        XCTAssertEqual(IslandMotion.Spring.bubble.base, Given(duration: 0.42, bounce: 0.32))
        XCTAssertEqual(IslandMotion.Spring.content.base, Given(duration: 0.28, bounce: 0.12))
        XCTAssertEqual(IslandMotion.Spring.digits.base, Given(duration: 0.35, bounce: 0))
        XCTAssertEqual(IslandMotion.Spring.control.base, Given(duration: 0.24, bounce: 0.1))
        XCTAssertEqual(IslandMotion.Spring.release.base, Given(duration: 0.3, bounce: 0.3))
        XCTAssertEqual(IslandMotion.Spring.all.count, 8, "every spring the island has, and no more")
        // The fades that stand in for them under Reduce Motion.
        XCTAssertEqual(IslandMotion.Spring.open.still, 0.18)
        XCTAssertEqual(IslandMotion.Spring.close.still, 0.16)
        XCTAssertEqual(IslandMotion.Spring.navigate.still, 0.16)
        XCTAssertEqual(IslandMotion.Spring.bubble.still, 0.18)
        XCTAssertEqual(IslandMotion.Spring.content.still, 0.15)
        XCTAssertEqual(IslandMotion.Spring.digits.still, 0.15)
        XCTAssertEqual(IslandMotion.Spring.control.still, 0.12)
        XCTAssertEqual(IslandMotion.Spring.release.still, 0.12)
    }

    func testTheShippedTuningChangesNothing() {
        let faithful = IslandMotion.Preset.faithful.tuning
        XCTAssertEqual(faithful, IslandMotion.Tuning(duration: 1, bounce: 1))
        for spring in IslandMotion.Spring.all {
            XCTAssertEqual(IslandMotion.scaled(duration: spring.base.duration, bounce: spring.base.bounce, by: faithful),
                           spring.base, "at 1 and 1 a spring is given exactly its own numbers")
        }
    }

    /// The curves themselves, not only the arithmetic behind them: what a view is handed at
    /// the shipped tuning is what it was handed before there was a tuning at all.
    func testTheDefaultsMakeExactlyTheSpringsThatShippedBefore() {
        let faithful = IslandMotion.Preset.faithful.tuning
        XCTAssertEqual(IslandMotion.spring(.open, tuning: faithful, reduced: false), .spring(duration: 0.44, bounce: 0.28))
        XCTAssertEqual(IslandMotion.spring(.close, tuning: faithful, reduced: false), .spring(duration: 0.32, bounce: 0))
        XCTAssertEqual(IslandMotion.spring(.navigate, tuning: faithful, reduced: false), .spring(duration: 0.34, bounce: 0.06))
        XCTAssertEqual(IslandMotion.spring(.bubble, tuning: faithful, reduced: false), .spring(duration: 0.42, bounce: 0.32))
        XCTAssertEqual(IslandMotion.spring(.content, tuning: faithful, reduced: false), .spring(duration: 0.28, bounce: 0.12))
        XCTAssertEqual(IslandMotion.spring(.digits, tuning: faithful, reduced: false), .spring(duration: 0.35, bounce: 0))
        XCTAssertEqual(IslandMotion.spring(.control, tuning: faithful, reduced: false), .spring(duration: 0.24, bounce: 0.1))
        XCTAssertEqual(IslandMotion.spring(.release, tuning: faithful, reduced: false), .spring(duration: 0.3, bounce: 0.3))
        XCTAssertEqual(IslandMotion.spring(.open, tuning: faithful, reduced: true), .easeOut(duration: 0.18))
    }

    func testCalmTakesTheBounceOutAndLeavesTheTiming() {
        let calm = IslandMotion.Preset.calm.tuning
        for spring in IslandMotion.Spring.all {
            let given = IslandMotion.scaled(duration: spring.base.duration, bounce: spring.base.bounce, by: calm)
            XCTAssertEqual(given.duration, spring.base.duration)
            XCTAssertEqual(given.bounce, 0, "no spring is left with any overshoot")
        }
        XCTAssertEqual(IslandMotion.spring(.open, tuning: calm, reduced: false), .spring(duration: 0.44, bounce: 0))
    }

    func testInstantHalvesTheTimingAndTakesTheBounceOut() {
        let instant = IslandMotion.Preset.instant.tuning
        let opening = IslandMotion.scaled(duration: 0.44, bounce: 0.28, by: instant)
        XCTAssertEqual(opening.duration, 0.22, accuracy: 1e-12)
        XCTAssertEqual(opening.bounce, 0)
        for spring in IslandMotion.Spring.all {
            let given = IslandMotion.scaled(duration: spring.base.duration, bounce: spring.base.bounce, by: instant)
            XCTAssertEqual(given.duration, spring.base.duration / 2, accuracy: 1e-12)
            XCTAssertEqual(given.bounce, 0)
        }
    }

    func testReduceMotionStillWinsOverTheTuning() {
        XCTAssertEqual(IslandMotion.spring(.open, tuning: IslandMotion.Preset.instant.tuning, reduced: true),
                       .easeOut(duration: 0.18),
                       "the fade is the spring's own, untouched by a hand on the springs")
        XCTAssertEqual(IslandMotion.spring(.open, tuning: IslandMotion.Tuning(duration: 2, bounce: 1.5), reduced: true),
                       .easeOut(duration: 0.18))
    }

    func testTheTuningIsHeldWithinItsRangesAtBothEnds() {
        XCTAssertEqual(IslandMotion.Tuning(duration: 0.1, bounce: -1).clamped, IslandMotion.Tuning(duration: 0.4, bounce: 0))
        XCTAssertEqual(IslandMotion.Tuning(duration: 9, bounce: 4).clamped, IslandMotion.Tuning(duration: 2, bounce: 1.5))
        XCTAssertEqual(IslandMotion.Tuning(duration: 0.4, bounce: 1.5).clamped, IslandMotion.Tuning(duration: 0.4, bounce: 1.5),
                       "the ends themselves are allowed")
        XCTAssertEqual(IslandMotion.Tuning(duration: 2, bounce: 0).clamped, IslandMotion.Tuning(duration: 2, bounce: 0))
        XCTAssertEqual(IslandMotion.Tuning(duration: 1.3, bounce: 0.7).clamped, IslandMotion.Tuning(duration: 1.3, bounce: 0.7),
                       "and anything between them is left alone")
    }

    /// What is stored reaches the springs through the same clamp, so a number edited into
    /// defaults by hand is held the way a slider would have held it.
    func testWhatIsStoredReachesTheSpringsClamped() throws {
        let prefs = Preferences.shared
        let wasDuration = prefs.motionDuration
        let wasBounce = prefs.motionBounce
        defer {
            prefs.motionDuration = wasDuration
            prefs.motionBounce = wasBounce
        }
        prefs.motionDuration = 9
        prefs.motionBounce = -3
        XCTAssertEqual(IslandMotion.tuning, IslandMotion.Tuning(duration: 2, bounce: 0))
        prefs.motionDuration = 0.5
        prefs.motionBounce = 0
        XCTAssertEqual(IslandMotion.tuning, IslandMotion.Preset.instant.tuning)
        try XCTSkipIf(IslandMotion.reduceMotion, "this machine is already asking for less motion")
        XCTAssertEqual(IslandMotion.open, .spring(duration: 0.22, bounce: 0),
                       "and the live curve follows the setting the moment it changes, with nothing cached")
    }

    func testAPresetIsKnownByItsNumbersAlone() {
        XCTAssertEqual(IslandMotion.Preset.matching(IslandMotion.Tuning(duration: 1, bounce: 1)), .faithful)
        XCTAssertEqual(IslandMotion.Preset.matching(IslandMotion.Tuning(duration: 1, bounce: 0)), .calm)
        XCTAssertEqual(IslandMotion.Preset.matching(IslandMotion.Tuning(duration: 0.5, bounce: 0)), .instant)
        XCTAssertNil(IslandMotion.Preset.matching(IslandMotion.Tuning(duration: 1.2, bounce: 1)),
                     "anywhere the sliders can go that no preset is, is custom")
        XCTAssertEqual(IslandMotion.Preset.allCases.map(\.title), ["Faithful", "Calm", "Instant"])
    }

    func testTheMotionPaneAnswersToItsName() {
        XCTAssertEqual(SettingsSection.named("Motion"), .motion)
        XCTAssertEqual(SettingsSection.named("motion"), .motion)
        XCTAssertEqual(SettingsSection.motion.title, "Motion")
        // Between the island and its activities, where the sidebar reads top to bottom.
        let order = SettingsSection.allCases
        XCTAssertEqual(order.firstIndex(of: .motion), order.firstIndex(of: .island).map { $0 + 1 })
    }
}
