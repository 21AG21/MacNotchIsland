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

    func testKeyboardIlluminationIsTakenOnlyWhenTheBacklightAnswers() {
        // The illumination keys are among the keys the tap can take…
        XCTAssertTrue(MediaKeyInterceptor.interceptedKeyCodes.contains(MediaKeyInterceptor.MediaKey.illuminationUp))
        XCTAssertTrue(MediaKeyInterceptor.interceptedKeyCodes.contains(MediaKeyInterceptor.MediaKey.illuminationDown))
        XCTAssertEqual(MediaKeyInterceptor.interceptedKeyCodes, [0, 1, 2, 3, 7, 21, 22])
        // …but each is gated on the keyboard's own capability, which is off until the keyboard
        // client has answered and the switch for it is on: a Mac without a backlight keeps them
        // macOS's.
        XCTAssertEqual(MediaKeyInterceptor.capability(for: MediaKeyInterceptor.MediaKey.illuminationUp), \SystemHUDReplacement.Capabilities.keyboard)
        XCTAssertEqual(MediaKeyInterceptor.capability(for: MediaKeyInterceptor.MediaKey.illuminationDown), \SystemHUDReplacement.Capabilities.keyboard)
        XCTAssertFalse(SystemHUDReplacement.Capabilities().keyboard, "nothing is taken before anything has been asked")
    }

    func testEveryOtherKeyAsksForTheCapabilityItAlwaysDid() {
        XCTAssertEqual(MediaKeyInterceptor.capability(for: MediaKeyInterceptor.MediaKey.soundUp), \SystemHUDReplacement.Capabilities.volume)
        XCTAssertEqual(MediaKeyInterceptor.capability(for: MediaKeyInterceptor.MediaKey.soundDown), \SystemHUDReplacement.Capabilities.volume)
        XCTAssertEqual(MediaKeyInterceptor.capability(for: MediaKeyInterceptor.MediaKey.mute), \SystemHUDReplacement.Capabilities.mute)
        XCTAssertEqual(MediaKeyInterceptor.capability(for: MediaKeyInterceptor.MediaKey.brightnessUp), \SystemHUDReplacement.Capabilities.brightness)
        XCTAssertEqual(MediaKeyInterceptor.capability(for: MediaKeyInterceptor.MediaKey.brightnessDown), \SystemHUDReplacement.Capabilities.brightness)
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

/// A media key is taken from macOS only while an island is on screen to answer it. Taken while
/// every island was hidden, or under a card forced up, it changed the level and nothing said
/// so: the island drew nothing and macOS never saw the key to draw its own bezel.
final class MediaKeySuppressionTests: XCTestCase {
    private var center: ActivityCenter { ActivityCenter.shared }

    override func setUp() {
        super.setUp()
        center.resetForTesting()
        // Neither is put back by `resetForTesting`, and both hide every island.
        center.appSuppressed = false
        center.pause(for: 0)
    }

    override func tearDown() {
        center.appSuppressed = false
        center.pause(for: 0)
        center.resetForTesting()
        super.tearDown()
    }

    private func rungTimer() -> IslandActivity {
        IslandActivity(id: "timer", kind: .timer,
                       content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(), isFinished: true)), priority: 90)
    }

    // MARK: The rule

    func testAKeyIsTakenOnlyWhenTheMacCanDoItAndAnIslandCanSayItWasDone() {
        XCTAssertTrue(MediaKeyInterceptor.swallows(canAnswer: true, islandCanShow: true))
        XCTAssertFalse(MediaKeyInterceptor.swallows(canAnswer: true, islandCanShow: false),
                       "no island to show it: macOS's bezel rather than no answer at all")
        XCTAssertFalse(MediaKeyInterceptor.swallows(canAnswer: false, islandCanShow: true),
                       "a key the Mac cannot answer is macOS's, as it always was")
        XCTAssertFalse(MediaKeyInterceptor.swallows(canAnswer: false, islandCanShow: false))
    }

    func testAnIslandUnderAFullScreenAppCannotShowAKey() {
        XCTAssertTrue(MediaKeyInterceptor.islandCanShow(islands: ["a"], hidden: [], cardForcedUp: false))
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(islands: ["a"], hidden: ["a"], cardForcedUp: false))
    }

    func testAnyIslandStillShowingIsEnough() {
        XCTAssertTrue(MediaKeyInterceptor.islandCanShow(islands: ["a", "b"], hidden: ["b"], cardForcedUp: false),
                      "a film on the external display leaves the MacBook's island to show it")
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(islands: ["a", "b"], hidden: ["a", "b"], cardForcedUp: false))
    }

    func testNoIslandAtAllIsNoneToShowItOn() {
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(islands: [], hidden: [], cardForcedUp: false))
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(islands: [], hidden: ["gone"], cardForcedUp: false),
                       "a hidden display with no island on it is not an island left showing")
    }

    func testACardForcedUpKeepsAKeysDisplayOffTheIsland() {
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(islands: ["a"], hidden: [], cardForcedUp: true))
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(islands: ["a", "b"], hidden: ["b"], cardForcedUp: true))
    }

    // MARK: Read from the centre

    func testAnIslandShowingAndNothingInTheWayTakesTheKeys() {
        center.panelsRebuilt(["a"])
        XCTAssertTrue(MediaKeyInterceptor.islandCanShow(in: center))
    }

    func testBeforeAnyIslandIsBuiltTheKeysAreMacOSs() {
        XCTAssertTrue(center.livePanels.isEmpty)
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(in: center))
    }

    func testTheOnlyDisplayFullScreenHandsTheKeysBack() {
        center.panelsRebuilt(["a"])
        center.fullscreenPanels = ["a"]
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(in: center))
    }

    func testTheOtherDisplayFullScreenLeavesTheKeysWithTheIsland() {
        center.panelsRebuilt(["a", "b"])
        center.fullscreenPanels = ["b"]
        XCTAssertTrue(MediaKeyInterceptor.islandCanShow(in: center))
        center.fullscreenPanels = ["a", "b"]
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(in: center))
    }

    func testAPauseHandsTheKeysBackUntilItIsTakenBack() {
        center.panelsRebuilt(["a"])
        center.pause(for: 60)
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(in: center), "a pause, as Hide Island for 1 Hour sets")
        center.pause(for: 0)
        XCTAssertTrue(MediaKeyInterceptor.islandCanShow(in: center))
    }

    func testAnAppOnTheHideListHandsTheKeysBack() {
        center.panelsRebuilt(["a", "b"])
        center.appSuppressed = true
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(in: center), "every island hides for that app")
    }

    func testARingingTimerHandsTheKeysBackUnlessAPanelIsOpenOverIt() {
        center.panelsRebuilt(["a"])
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 5)
        XCTAssertNotNil(center.forcedCard)
        XCTAssertFalse(MediaKeyInterceptor.islandCanShow(in: center),
                       "a key's display would wait behind the card and be dropped")
        center.open(.activity(id: "timer"))
        XCTAssertTrue(center.isOpen)
        XCTAssertTrue(MediaKeyInterceptor.islandCanShow(in: center), "with a panel open it is a banner there")
    }

    // MARK: Where the tap thread reads it

    func testTheAnswerIsReadableFromTheTapThread() {
        let hud = SystemHUDReplacement.shared
        let saved = hud.canShowKeyDisplay()
        defer { hud.setCanShowKeyDisplay(saved) }
        hud.setCanShowKeyDisplay(true)
        XCTAssertTrue(DispatchQueue.global(qos: .userInteractive).sync { hud.canShowKeyDisplay() })
        hud.setCanShowKeyDisplay(false)
        XCTAssertFalse(DispatchQueue.global(qos: .userInteractive).sync { hud.canShowKeyDisplay() })
    }
}
