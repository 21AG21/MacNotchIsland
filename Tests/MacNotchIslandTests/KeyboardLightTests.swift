import XCTest
@testable import MacNotchIsland

/// The keyboard backlight's arithmetic: the keys step it on the same grid the display's keys use,
/// and nothing that reaches the client is ever outside 0...1. The client itself is private API
/// and is not here to be asked on a build machine; the rules around it are.
final class KeyboardLightTests: XCTestCase {
    func testAKeyMovesTheBacklightOneSixteenth() {
        XCTAssertEqual(KeyboardLight.stepped(from: 0.5, up: true, fine: false), 0.5625, accuracy: 1e-5)
        XCTAssertEqual(KeyboardLight.stepped(from: 0.5, up: false, fine: false), 0.4375, accuracy: 1e-5)
        XCTAssertEqual(KeyboardLight.coarseStep, 1.0 / 16.0, accuracy: 1e-9)
    }

    func testShiftAndOptionMoveItAQuarterOfThat() {
        XCTAssertEqual(KeyboardLight.fineStep, KeyboardLight.coarseStep / 4, accuracy: 1e-9)
        XCTAssertEqual(KeyboardLight.stepped(from: 0.5, up: true, fine: true), 0.515625, accuracy: 1e-5)
        XCTAssertEqual(KeyboardLight.stepped(from: 0.5, up: false, fine: true), 0.484375, accuracy: 1e-5)
    }

    func testAPressFromBetweenTwoNotchesLandsOnTheNextOne() {
        // The ambient light sensor leaves the backlight anywhere; a press still moves, and
        // lands on the grid rather than a sixteenth past wherever it was.
        XCTAssertEqual(KeyboardLight.stepped(from: 0.37, up: true, fine: false), 0.375, accuracy: 1e-5)
        XCTAssertEqual(KeyboardLight.stepped(from: 0.37, up: false, fine: false), 0.3125, accuracy: 1e-5)
    }

    func testItStopsAtEitherEnd() {
        XCTAssertEqual(KeyboardLight.stepped(from: 0, up: false, fine: false), 0, accuracy: 1e-6)
        XCTAssertEqual(KeyboardLight.stepped(from: 1, up: true, fine: false), 1, accuracy: 1e-6)
        XCTAssertEqual(KeyboardLight.stepped(from: 0.03, up: false, fine: false), 0, accuracy: 1e-6)
        XCTAssertEqual(KeyboardLight.stepped(from: 0.99, up: true, fine: true), 1, accuracy: 1e-6)
    }

    func testAReadingOffTheScaleIsHeldToIt() {
        XCTAssertEqual(KeyboardLight.clamped(-0.2), 0)
        XCTAssertEqual(KeyboardLight.clamped(1.4), 1)
        XCTAssertEqual(KeyboardLight.clamped(0.25), 0.25)
        XCTAssertEqual(KeyboardLight.clamped(.nan), 0, "not a number is not a level")
        XCTAssertEqual(KeyboardLight.clamped(.infinity), 0)
        // A step from a level off the scale starts from the scale.
        XCTAssertEqual(KeyboardLight.stepped(from: 3, up: false, fine: false), 0.9375, accuracy: 1e-5)
        XCTAssertEqual(KeyboardLight.stepped(from: -1, up: true, fine: false), 0.0625, accuracy: 1e-5)
    }

    func testTheKeyboardDrivenIsTheOneTheClientNames() {
        XCTAssertEqual(KeyboardLight.keyboard(from: [3, 7]), 3)
        let answer: [NSNumber] = [NSNumber(value: 3), NSNumber(value: 7)]
        let named = KeyboardLight.backlightIDs(answer: answer)
        XCTAssertEqual(named, [3, 7])
        XCTAssertEqual(KeyboardLight.keyboard(from: named), 3)
    }

    /// The method that lists the keyboards has gone, so nothing was asked: the built-in
    /// keyboard's number is the best guess there is.
    func testAClientThatCannotBeAskedGetsTheBuiltInKeyboard() {
        XCTAssertEqual(KeyboardLight.keyboard(from: nil), 1)
    }

    /// The method is there and answered nothing. That is an answer — no backlit keyboard — and
    /// not the same thing as a method that has gone: no slider and no display for it.
    func testAClientThatAnswersNothingHasNoBacklight() {
        let ids = KeyboardLight.backlightIDs(answer: nil)
        XCTAssertEqual(ids, [], "a nil answer is an empty list, not a client that could not be asked")
        XCTAssertNil(KeyboardLight.keyboard(from: ids), "and an empty list is no backlight to set")
        XCTAssertEqual(KeyboardLight.backlightIDs(answer: "not a list"), [], "nor is an answer that cannot be read")
        XCTAssertNil(KeyboardLight.keyboard(from: []))
    }

    func testAControlScrollMovesTheBacklight() {
        let up = GestureRouter.decide(dx: 0, dy: -40, context: .idle, wantsKeyboard: true)
        guard case .keyboard(let delta) = up else { return XCTFail("expected the keyboard, got \(up)") }
        XCTAssertGreaterThan(delta, 0, "scrolling up brightens, the way it raises the volume")
        let down = GestureRouter.decide(dx: 0, dy: 40, context: .idle, wantsKeyboard: true)
        guard case .keyboard(let dim) = down else { return XCTFail("expected the keyboard, got \(down)") }
        XCTAssertLessThan(dim, 0)
        XCTAssertEqual(GestureRouter.keyboardStep, GestureRouter.brightnessStep, accuracy: 1e-9,
                       "one scroll, one feel, whatever it moves")
    }

    func testControlWithOptionIsNeitherAndTheScrollStaysTheVolume() {
        guard case .volume = GestureRouter.decide(dx: 0, dy: -40, context: .idle,
                                                  wantsBrightness: true, wantsKeyboard: true) else {
            return XCTFail("two modifiers at once mean neither clearly enough to act on")
        }
        let list = GestureRouter.Context.panel(index: 0, count: 4, scrolls: true)
        XCTAssertEqual(GestureRouter.decide(dx: 0, dy: -40, context: list, wantsKeyboard: true), .none,
                       "a section that scrolls keeps its scroll")
    }

    /// The automatic switch is held the way the level is: a read straight after the write can
    /// come back before CoreBrightness has taken it, and the checkbox snapped back.
    func testTheAutomaticSwitchIsHeldUntilTheKeyboardAgreesOrTheHoldRunsOut() {
        let now: TimeInterval = 100
        let held = (value: true, until: now + KeyboardLight.writeSettle)
        XCTAssertFalse(KeyboardLight.acceptsAutomatic(false, holding: held, now: now),
                       "a reading older than the click does not undo it")
        XCTAssertTrue(KeyboardLight.acceptsAutomatic(true, holding: held, now: now), "agreeing settles it at once")
        XCTAssertTrue(KeyboardLight.acceptsAutomatic(false, holding: held, now: now + KeyboardLight.writeSettle),
                      "past the hold, the keyboard's answer is the answer")
        XCTAssertTrue(KeyboardLight.acceptsAutomatic(false, holding: nil, now: now), "with nothing held, any reading")
    }
}
