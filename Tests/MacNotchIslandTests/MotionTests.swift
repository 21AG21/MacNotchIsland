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

    func testTheSpringsAreAllDifferentFromEachOther() throws {
        try XCTSkipIf(IslandMotion.reduceMotion, "this machine is already asking for less motion")
        XCTAssertNotEqual(IslandMotion.open, IslandMotion.navigate)
        XCTAssertNotEqual(IslandMotion.content, IslandMotion.control)
        XCTAssertNotEqual(IslandMotion.bubble, IslandMotion.open)
        // The eases are unaffected by the setting either way.
        XCTAssertEqual(IslandMotion.hover, .easeOut(duration: 0.12))
    }
}
