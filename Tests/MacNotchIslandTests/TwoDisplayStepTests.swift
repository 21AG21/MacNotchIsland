import AppKit
import XCTest
@testable import MacNotchIsland

/// With an island on each of two displays: which island a step, a digit or a drag is about,
/// and how the pointer crossing from one island to the other is read.
final class TwoDisplayStepTests: XCTestCase {
    private var center: ActivityCenter { ActivityCenter.shared }

    override func setUp() {
        super.setUp()
        center.resetForTesting()
        let p = Preferences.shared
        p.hoverToExpand = true
        p.expandOnIdleHover = true
        p.hoverDelay = 0.01
        HomeSection.allCases.forEach { $0.setEnabled(true, in: p) }
    }

    override func tearDown() {
        center.resetForTesting()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval) {
        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }

    /// The panel pinned on a's island at `ring[pinned]`, and the pointer resting on b's, its
    /// peek moved to `ring[peeked]`. Returns the ring.
    @discardableResult
    private func pinnedOnAPeekingOnB(pinned: Int, peeked: Int) -> [IslandView] {
        let ring = center.ring
        XCTAssertGreaterThan(ring.count, max(pinned, peeked) + 1, "room to step forward from either")
        center.open(ring[pinned], panel: "a")
        center.setHovering(true, panel: "b")
        settle(0.1)
        center.select(ring[peeked], panel: "b")
        XCTAssertEqual(center.currentView(on: "a"), ring[pinned])
        XCTAssertEqual(center.currentView(on: "b"), ring[peeked])
        return ring
    }

    // MARK: - Steps

    func testAKeyStepsThePanelThatHasTheKeyboard() {
        // The panel pinned on a holds the keyboard. Tab and the arrows stepped the peek under
        // the pointer on b instead, and from where a's panel was in the ring.
        let ring = pinnedOnAPeekingOnB(pinned: 1, peeked: 3)
        XCTAssertTrue(center.step(forward: true, wrap: false))
        XCTAssertEqual(center.currentView(on: "a"), ring[2], "the panel pinned on a steps")
        XCTAssertEqual(center.openPanel, "a", "and stays on a")
        XCTAssertEqual(center.currentView(on: "b"), ring[3], "the peek on b is left where it was")
    }

    func testASwipeOnThePeekedIslandStepsItsOwnPeek() {
        let ring = pinnedOnAPeekingOnB(pinned: 1, peeked: 3)
        XCTAssertTrue(center.step(forward: true, wrap: false, panel: "b"))
        XCTAssertEqual(center.currentView(on: "b"), ring[4], "from where b's peek was, not from a's panel")
        XCTAssertEqual(center.currentView(on: "a"), ring[1], "the panel pinned on a is not touched")
        XCTAssertEqual(center.openPanel, "a")
        XCTAssertFalse(center.openHere("b"), "and b's peek is still a peek")
    }

    func testADigitGoesToThePanelThatHasTheKeyboard() {
        let ring = pinnedOnAPeekingOnB(pinned: 1, peeked: 3)
        XCTAssertTrue(center.selectSlot(0))
        XCTAssertEqual(center.currentView(on: "a"), ring[0])
        XCTAssertEqual(center.currentView(on: "b"), ring[3])
    }

    func testASwipeStepsAPanelOpenEverywhereWithoutMovingIt() {
        let ring = center.ring
        center.open(ring[1])
        XCTAssertNil(center.openPanel, "the shortcut opens it on every island")
        center.setHovering(true, panel: "b")
        settle(0.1)
        XCTAssertTrue(center.step(forward: true, wrap: false, panel: "b"))
        XCTAssertEqual(center.openView, ring[2])
        XCTAssertNil(center.openPanel, "a step changes the view, not the displays it is on")
    }

    func testWithNothingOpenAKeyStepsThePeekUnderThePointer() {
        let ring = center.ring
        center.setHovering(true, panel: "b")
        settle(0.1)
        center.select(ring[1], panel: "b")
        XCTAssertTrue(center.step(forward: true, wrap: false))
        XCTAssertEqual(center.currentView(on: "b"), ring[2])
        XCTAssertFalse(center.isOpen, "a peek still, not pinned")
        XCTAssertNil(center.currentView(on: "a"), "and nothing on the other island")
    }

    // MARK: - A drag

    func testADragOverThePeekedIslandIsJudgedByItsOwnSection() {
        // a is pinned on Actions, whose tiles take drops; b is peeking on Now Playing, which
        // takes none. The drag over b was judged by a's section and showed no well.
        center.open(.home(tab: HomeSection.actions.rawValue), panel: "a")
        center.setHovering(true, panel: "b")
        settle(0.1)
        center.select(.home(tab: HomeSection.music.rawValue), panel: "b")
        center.setDragTargeted(true, panel: "b")
        XCTAssertEqual(center.presentation(for: "b"), .shelf)
    }

    func testADragOverAPeekedActionsRowLeavesItsTilesAlone() {
        center.open(.home(tab: HomeSection.music.rawValue), panel: "a")
        center.setHovering(true, panel: "b")
        settle(0.1)
        let actions = IslandView.home(tab: HomeSection.actions.rawValue)
        center.select(actions, panel: "b")
        center.setDragTargeted(true, panel: "b")
        XCTAssertEqual(center.presentation(for: "b"), .panel(actions), "the file is on its way to a tile")
    }

    // MARK: - The keyboard

    func testAClickOnTheOtherIslandThatOpensNothingAsksForNothing() {
        Preferences.shared.panelKeysEnabled = true
        // A pill with nothing to open and nothing to do.
        center.upsert(IslandActivity(id: "silent", kind: .silent, content: .silent(SilentState(isSilent: true)), priority: 70))
        center.setHovering(true, panel: "a")
        settle(0.1)
        center.pinPeek(panel: "a")
        XCTAssertTrue(center.isOpen)
        XCTAssertFalse(center.keyboardInvited, "a click on a control pins without asking")
        center.tap(panel: "b")
        XCTAssertFalse(center.keyboardInvited, "a click on b opened nothing, and asked nothing of a's panel")
        center.tap(panel: "a")
        XCTAssertTrue(center.keyboardInvited, "a click on a's own panel does")
    }

    // MARK: - The pointer between the two

    func testCrossingToTheOtherIslandIsLeavingThisOne() {
        center.setHovering(true, panel: "a")
        settle(0.1)
        center.pinPeek(panel: "a")
        // Closed under the pointer: a shows no peek until the pointer has left it.
        center.collapse(reason: "escape")
        // It leaves, and reaches b inside a's grace.
        center.setHovering(false, panel: "a")
        center.setHovering(true, panel: "b")
        settle(0.1)
        XCTAssertEqual(center.hoverPanel, "b")
        center.setHovering(false, panel: "b")
        center.setHovering(true, panel: "a")
        settle(0.1)
        guard case .panel = center.presentation(for: "a") else {
            return XCTFail("a was left, so it peeks again; it stayed suppressed for this visit")
        }
    }

    func testAPointerThatOnlyCrossesTheOtherIslandLeavesNeitherPeeking() {
        center.setHovering(true, panel: "a")
        settle(0.1)
        XCTAssertEqual(center.hoverPanel, "a")
        center.setHovering(false, panel: "a")
        center.setHovering(true, panel: "b")
        // Gone from b again before its hover delay.
        center.setHovering(false, panel: "b")
        settle(ActivityCenter.hoverExitGrace + 0.2)
        XCTAssertNil(center.hoverPanel, "nobody is on either island; a used to go on peeking")
        XCTAssertEqual(center.presentation(for: "a"), .idle)
    }

    func testClosingThePeekOnOneIslandLeavesThePanelOnTheOther() {
        // A swipe up on b's peek, with the panel pinned on a. It went to `collapse`, which
        // closed a's panel too.
        let ring = pinnedOnAPeekingOnB(pinned: 1, peeked: 3)
        center.closePeek(panel: "b")
        XCTAssertNil(center.currentView(on: "b"), "the peek on b is gone")
        XCTAssertTrue(center.isOpen)
        XCTAssertEqual(center.openPanel, "a")
        XCTAssertEqual(center.currentView(on: "a"), ring[1], "and the panel pinned on a is as it was")
        center.closePeek(panel: "a")
        XCTAssertEqual(center.currentView(on: "a"), ring[1], "a pinned panel is not a peek, and is left to a close")
        // The pointer is still on b and says so again: no peek until it has left.
        center.setHovering(true, panel: "b")
        settle(0.1)
        XCTAssertNil(center.currentView(on: "b"))
        center.setHovering(false, panel: "b")
        settle(ActivityCenter.hoverExitGrace + 0.1)
        center.setHovering(true, panel: "b")
        settle(0.1)
        XCTAssertNotNil(center.currentView(on: "b"), "it left and came back: a peek again")
    }

    // MARK: - Growth

    func testAPeekGrowingOnOneIslandIsNoGrowthOnTheOther() {
        // The panel pinned on a; the peek grows on b under the pointer. A click on a's panel
        // is a click on what it lands on; only b's is taken for one aimed at its pill.
        pinnedOnAPeekingOnB(pinned: 1, peeked: 3)
        XCTAssertEqual(center.grewOn, "b")
        XCTAssertEqual(center.sinceGrew(on: "a"), .infinity)
        XCTAssertLessThan(center.sinceGrew(on: "b"), 1)
    }

    func testTheSameViewOpenedFromASecondIslandGrowsThatIsland() {
        let ring = center.ring
        center.open(ring[1], panel: "a")
        XCTAssertEqual(center.grewOn, "a")
        center.open(ring[1], panel: "b")
        XCTAssertNil(center.openPanel, "it shows on both")
        XCTAssertEqual(center.grewOn, "b", "and b is the island that grew")
    }

    // MARK: - A peek left on the other island

    func testAPeekLeftOnTheOtherIslandIsNotWhereTheNextVisitOpens() {
        // The panel pinned on a, the peek on b moved to another section, the pointer gone
        // from b: the peek stayed, and the next visit to b opened on it instead of on what
        // was playing.
        center.upsert(IslandActivity(id: "nowplaying", kind: .nowPlaying, content: .nowPlaying(NowPlayingService.fakeTrack()),
                                     priority: 50))
        let music = IslandView.home(tab: HomeSection.music.rawValue)
        let others = center.ring.indices.filter { center.ring[$0] != music }
        guard others.count >= 3 else { return XCTFail("sections enough to pin one and peek at another") }
        let ring = pinnedOnAPeekingOnB(pinned: others[0], peeked: others[1])
        center.setHovering(false, panel: "b")
        settle(ActivityCenter.hoverExitGrace + 0.2)
        XCTAssertNil(center.hoverPanel)
        XCTAssertNil(center.peekView, "no pointer on any island, no peek")
        XCTAssertEqual(center.currentView(on: "a"), ring[others[0]], "the panel pinned on a is as it was")
        center.setHovering(true, panel: "b")
        settle(0.1)
        XCTAssertEqual(center.currentView(on: "b"), music, "a fresh peek, on what is playing")
    }

    // MARK: - Who takes the keyboard

    private typealias Island = PanelKeyboard.Island

    func testAnIslandHiddenUnderAFullScreenAppDoesNotTakeTheKeyboard() {
        // Open everywhere from the shortcut, a film full screen on b, the pointer there: the
        // invisible window over the film took key status, and Notes on a took no typing.
        let a = Island(id: "a", underPointer: false, onMainScreen: true, suppressed: false)
        let b = Island(id: "b", underPointer: true, onMainScreen: false, suppressed: true)
        XCTAssertEqual(PanelKeyboard.owner(openPanel: nil, islands: [a, b]), "a", "the island that is drawn")
        XCTAssertEqual(PanelKeyboard.owner(openPanel: nil, islands: [b, a]), "a", "whatever order the windows are in")
        let bOnMain = Island(id: "b", underPointer: true, onMainScreen: true, suppressed: true)
        let aElsewhere = Island(id: "a", underPointer: false, onMainScreen: false, suppressed: false)
        XCTAssertEqual(PanelKeyboard.owner(openPanel: nil, islands: [bOnMain, aElsewhere]), "a",
                       "not the main screen's either, when that is the one hidden")
        XCTAssertNil(PanelKeyboard.owner(openPanel: "b", islands: [a, b]), "pinned on the hidden island: nobody types")
        XCTAssertNil(PanelKeyboard.owner(openPanel: nil, islands: [b]), "and with every island hidden, nobody")
    }

    func testTheIslandUnderThePointerTakesTheKeyboardAmongThoseDrawn() {
        let a = Island(id: "a", underPointer: false, onMainScreen: true, suppressed: false)
        let b = Island(id: "b", underPointer: true, onMainScreen: false, suppressed: false)
        XCTAssertEqual(PanelKeyboard.owner(openPanel: nil, islands: [a, b]), "b", "the one under the pointer")
        let bAway = Island(id: "b", underPointer: false, onMainScreen: false, suppressed: false)
        XCTAssertEqual(PanelKeyboard.owner(openPanel: nil, islands: [bAway, a]), "a", "failing that, the main screen's")
        let aAway = Island(id: "a", underPointer: false, onMainScreen: false, suppressed: false)
        XCTAssertEqual(PanelKeyboard.owner(openPanel: nil, islands: [bAway, aAway]), "b", "failing that, the first")
        XCTAssertEqual(PanelKeyboard.owner(openPanel: "a", islands: [a, b]), "a", "pinned on one island: that one types")
        XCTAssertNil(PanelKeyboard.owner(openPanel: nil, islands: []))
    }

    // MARK: - The pointer on a screen's top row

    func testAPointerOnTheTopRowIsOnTheDisplayWhoseTopItIs() {
        // AppKit reads the top row of a screen as y == maxY. `CGRect.contains` put it off the
        // screen, and off the island whose window starts at that edge.
        let lower = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let upper = NSRect(x: 0, y: 982, width: 1920, height: 1080)
        let top = NSPoint(x: 756, y: 982)
        XCTAssertTrue(NotchPanel.pointer(top, isIn: lower), "the lower display's top row")
        XCTAssertFalse(NotchPanel.pointer(top, isIn: upper), "not the upper display's bottom")
        XCTAssertFalse(lower.contains(top), "which is where the rectangle's own rule put it")
        XCTAssertTrue(NotchPanel.pointer(NSPoint(x: 756, y: 500), isIn: lower))
        XCTAssertFalse(NotchPanel.pointer(NSPoint(x: 756, y: 1100), isIn: lower))

        // The island's window hangs from that edge; its outline is asked about the middle of
        // the top row there, and about any other point as it is.
        let window = NSRect(x: 596, y: 642, width: 320, height: 340)
        XCTAssertTrue(NotchPanel.pointer(top, isIn: window))
        XCTAssertEqual(NotchPanel.pointerSample(top, in: window), NSPoint(x: 756, y: 981.5))
        let below = NSPoint(x: 756, y: 960)
        XCTAssertEqual(NotchPanel.pointerSample(below, in: window), below)
    }
}
