import XCTest
@testable import MacNotchIsland

final class MediaKeyDecodingTests: XCTestCase {
    /// Builds a `data1` payload the way the window server does.
    private func data1(keyCode: Int, keyState: Int, isRepeat: Bool = false) -> Int {
        (keyCode << 16) | (keyState << 8) | (isRepeat ? 1 : 0)
    }

    private let down = 0x0A
    private let up = 0x0B

    func testDecodesKeyDown() {
        let d = MediaKeyInterceptor.decode(data1: data1(keyCode: MediaKeyInterceptor.MediaKey.soundUp, keyState: down))
        XCTAssertEqual(d.keyCode, 0)
        XCTAssertTrue(d.isDown)
        XCTAssertFalse(d.isRepeat)
    }

    func testDecodesKeyUp() {
        let d = MediaKeyInterceptor.decode(data1: data1(keyCode: MediaKeyInterceptor.MediaKey.soundDown, keyState: up))
        XCTAssertEqual(d.keyCode, 1)
        XCTAssertFalse(d.isDown)
        XCTAssertFalse(d.isRepeat)
    }

    func testDecodesRepeat() {
        let d = MediaKeyInterceptor.decode(data1: data1(keyCode: MediaKeyInterceptor.MediaKey.brightnessDown,
                                                        keyState: down, isRepeat: true))
        XCTAssertEqual(d.keyCode, 3)
        XCTAssertTrue(d.isDown)
        XCTAssertTrue(d.isRepeat)
    }

    func testDecodesEveryKnownKeyCode() {
        let codes = [MediaKeyInterceptor.MediaKey.soundUp,
                     MediaKeyInterceptor.MediaKey.soundDown,
                     MediaKeyInterceptor.MediaKey.brightnessUp,
                     MediaKeyInterceptor.MediaKey.brightnessDown,
                     MediaKeyInterceptor.MediaKey.mute,
                     MediaKeyInterceptor.MediaKey.illuminationUp,
                     MediaKeyInterceptor.MediaKey.illuminationDown]
        XCTAssertEqual(codes, [0, 1, 2, 3, 7, 21, 22])
        for code in codes {
            XCTAssertEqual(MediaKeyInterceptor.decode(data1: data1(keyCode: code, keyState: down)).keyCode, code)
        }
    }

    /// The real payload carries junk in the low flag bits; only bit 0 is the repeat flag.
    func testIgnoresOtherFlagBits() {
        let raw = (MediaKeyInterceptor.MediaKey.mute << 16) | 0x0A00 | 0x0026
        let d = MediaKeyInterceptor.decode(data1: raw)
        XCTAssertEqual(d.keyCode, 7)
        XCTAssertTrue(d.isDown)
        XCTAssertFalse(d.isRepeat)
    }

    func testKeyCodeMaskDoesNotLeakHighBits() {
        let d = MediaKeyInterceptor.decode(data1: 0x7FFF_0000 | 0x0A00)
        XCTAssertEqual(d.keyCode, 0x7FFF)
        XCTAssertTrue(d.isDown)
    }

    func testKeyboardIlluminationIsNotIntercepted() {
        XCTAssertFalse(MediaKeyInterceptor.interceptedKeyCodes.contains(MediaKeyInterceptor.MediaKey.illuminationUp))
        XCTAssertFalse(MediaKeyInterceptor.interceptedKeyCodes.contains(MediaKeyInterceptor.MediaKey.illuminationDown))
        XCTAssertEqual(MediaKeyInterceptor.interceptedKeyCodes, [0, 1, 2, 3, 7])
    }

    // MARK: Step maths

    func testCoarseStepMovesOneSixteenth() {
        let step = MediaKeyInterceptor.coarseStep
        XCTAssertEqual(MediaKeyInterceptor.stepped(from: 0.5, delta: 1, step: step), 0.5625, accuracy: 1e-5)
        XCTAssertEqual(MediaKeyInterceptor.stepped(from: 0.5, delta: -1, step: step), 0.4375, accuracy: 1e-5)
    }

    func testStepsSnapToTheGrid() {
        let step = MediaKeyInterceptor.coarseStep
        XCTAssertEqual(MediaKeyInterceptor.stepped(from: 0.37, delta: 1, step: step), 0.375, accuracy: 1e-5)
        XCTAssertEqual(MediaKeyInterceptor.stepped(from: 0.37, delta: -1, step: step), 0.3125, accuracy: 1e-5)
    }

    func testStepsClampToRange() {
        let step = MediaKeyInterceptor.coarseStep
        XCTAssertEqual(MediaKeyInterceptor.stepped(from: 0, delta: -1, step: step), 0, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyInterceptor.stepped(from: 1, delta: 1, step: step), 1, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyInterceptor.stepped(from: 0.03, delta: -1, step: step), 0, accuracy: 1e-6)
    }

    func testFineStepIsAQuarterNotch() {
        XCTAssertEqual(MediaKeyInterceptor.fineStep, MediaKeyInterceptor.coarseStep / 4, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyInterceptor.stepped(from: 0.5, delta: 1, step: MediaKeyInterceptor.fineStep),
                       0.515625, accuracy: 1e-5)
    }

    func testTrustFlagIsReadable() {
        // Just exercising the accessor: the CI machine grants nothing, but it must not trap.
        _ = MediaKeyInterceptor.isTrusted
    }

    // MARK: A tap switched off behind our back

    func testATapThatIsCarryingTheKeysIsLeftAlone() {
        XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: true, revivalsSoFar: 0), .carrying)
        // Even with every attempt spent: a tap that answers is a tap that answers.
        XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: true,
                                                     revivalsSoFar: MediaKeyInterceptor.maxTapRevivals),
                       .carrying)
    }

    func testATapFoundSwitchedOffIsSwitchedBackOn() {
        XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: false, revivalsSoFar: 0), .revivable)
        XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: false, revivalsSoFar: 1), .revivable)
    }

    func testATapThatWillNotComeBackIsNotRetriedForever() {
        let budget = MediaKeyInterceptor.maxTapRevivals
        XCTAssertGreaterThan(budget, 0)
        for spent in 0..<budget {
            XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: false, revivalsSoFar: spent), .revivable)
        }
        XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: false, revivalsSoFar: budget), .lost)
        XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: false, revivalsSoFar: budget + 7), .lost)
    }

    func testTheRevivalBudgetIsSpentOneAttemptAtATime() {
        XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: false, revivalsSoFar: 0, budget: 1), .revivable)
        XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: false, revivalsSoFar: 1, budget: 1), .lost)
        // No budget at all is a tap nobody asks about twice.
        XCTAssertEqual(MediaKeyInterceptor.tapHealth(isEnabled: false, revivalsSoFar: 0, budget: 0), .lost)
    }

    // MARK: An older copy on its way out

    func testACopyThatHasAlreadyGoneIsNotWaitedFor() {
        XCTAssertEqual(CopyRetirement.next(stillRunning: 0, secondsLeft: 2), .done)
        // Gone is gone, deadline or no deadline: there is nothing left to force.
        XCTAssertEqual(CopyRetirement.next(stillRunning: 0, secondsLeft: -1), .done)
    }

    func testACopyStillOnItsWayOutIsWaitedFor() {
        XCTAssertEqual(CopyRetirement.next(stillRunning: 1, secondsLeft: 1.5), .waitAgain)
        XCTAssertEqual(CopyRetirement.next(stillRunning: 3, secondsLeft: 0.01), .waitAgain)
    }

    func testACopyThatWillNotQuitIsNotWaitedForForever() {
        XCTAssertEqual(CopyRetirement.next(stillRunning: 1, secondsLeft: 0), .force)
        XCTAssertEqual(CopyRetirement.next(stillRunning: 2, secondsLeft: -0.3), .force)
    }
}
