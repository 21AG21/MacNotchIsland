import XCTest
@testable import MacNotchIsland

/// The rules behind the island's dealings with Spaces, displays and the mouse: what the panel
/// lets through, which island shows what was opened, when an app coming forward is the user
/// leaving, and which display a full-screen app takes with it.
final class SpacesAndDisplaysTests: XCTestCase {
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
        HomeSection.allCases.forEach { $0.setEnabled(true, in: Preferences.shared) }
        super.tearDown()
    }

    // MARK: - Letting the mouse through

    func testTheWindowIsTransparentToTheMouseUntilThePointerIsOnTheIsland() {
        XCTAssertTrue(NotchPanel.passesThrough(onIsland: false, engaged: false, suppressed: false))
        XCTAssertFalse(NotchPanel.passesThrough(onIsland: true, engaged: false, suppressed: false))
    }

    func testAnEventStreamThatBeganOnTheIslandFinishesOnIt() {
        // A slider dragged past the edge, a file over the shelf, the button still down.
        XCTAssertFalse(NotchPanel.passesThrough(onIsland: false, engaged: true, suppressed: false))
    }

    func testAHiddenIslandTakesNothing() {
        XCTAssertTrue(NotchPanel.passesThrough(onIsland: true, engaged: true, suppressed: true))
    }

    // MARK: - Which island shows the open view

    func testAClickOpensTheIslandItWasClickedOn() {
        center.tap(panel: "screen-1")
        guard case .panel = center.presentation(for: "screen-1") else { return XCTFail("opens where it was clicked") }
        XCTAssertEqual(center.presentation(for: "screen-2"), .idle, "the other display's island stays as it was")
        guard case .panel = center.presentation(for: nil) else { return XCTFail("asked without a panel, it is open") }
        XCTAssertEqual(center.openPanel, "screen-1")
    }

    func testTheShortcutOpensEveryIsland() {
        center.toggle()
        XCTAssertTrue(center.isOpen)
        XCTAssertNil(center.openPanel)
        guard case .panel = center.presentation(for: "screen-1"), case .panel = center.presentation(for: "screen-2") else {
            return XCTFail("opened from everywhere, it shows everywhere")
        }
    }

    func testAKeyboardStepStaysOnTheIslandThatWasOpened() {
        center.tap(panel: "screen-2")
        center.cycleView(forward: true)
        XCTAssertEqual(center.openPanel, "screen-2", "stepping names no island and stays where the panel is")
        XCTAssertEqual(center.presentation(for: "screen-1"), .idle)
    }

    func testClosingForgetsWhichIslandWasOpen() {
        center.tap(panel: "screen-1")
        center.collapse()
        XCTAssertNil(center.openPanel)
        center.tap(panel: "screen-1")
        center.clearInteraction()
        XCTAssertNil(center.openPanel)
    }

    func testTheRule() {
        XCTAssertTrue(ActivityCenter.shows(openPanel: nil, on: "screen-1"))
        XCTAssertTrue(ActivityCenter.shows(openPanel: "screen-1", on: nil))
        XCTAssertTrue(ActivityCenter.shows(openPanel: "screen-1", on: "screen-1"))
        XCTAssertFalse(ActivityCenter.shows(openPanel: "screen-1", on: "screen-2"))
    }

    // MARK: - A Space change is not leaving

    func testAnActivationRightAfterASpaceChangeIsNotLeaving() {
        let now = Date()
        XCTAssertFalse(ActivityCenter.leftForAnotherApp(now: now, lastSpaceChange: now.addingTimeInterval(-0.2)))
        XCTAssertTrue(ActivityCenter.leftForAnotherApp(now: now, lastSpaceChange: now.addingTimeInterval(-5)))
        XCTAssertTrue(ActivityCenter.leftForAnotherApp(now: now, lastSpaceChange: .distantPast))
    }

    func testTheActivationWaitsLongEnoughForTheSpaceToSpeak() {
        // The Space's notification follows the activation; the wait has to outlast that gap
        // and the grace has to cover the wait, or the check runs before the answer is in.
        XCTAssertGreaterThan(ActivityCenter.spaceChangeGrace, ActivityCenter.activationSettle)
    }

    // MARK: - Forgetting the pointer

    func testARebuildForgetsThePointerButNotWhatWasOpened() {
        Preferences.shared.hoverToExpand = true
        Preferences.shared.hoverDelay = 0.01
        center.setHovering(true, panel: "screen-1")
        let exp = expectation(description: "hovering")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(center.hoverPanel, "screen-1")
        center.setPressed(true, panel: "screen-1")   // pins the peek, as a press does
        center.setDragTargeted(true, panel: "screen-1")

        center.forgetPointer()
        XCTAssertNil(center.hoverPanel)
        XCTAssertNil(center.dragPanel)
        XCTAssertNil(center.pressedPanel)
        XCTAssertTrue(center.isOpen, "what a press pinned stays open; only the pointer is forgotten")
    }

    func testForgettingThePointerDropsAPeekThatNothingPinned() {
        Preferences.shared.hoverToExpand = true
        Preferences.shared.hoverDelay = 0.01
        center.setHovering(true, panel: "screen-1")
        let exp = expectation(description: "hovering")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertNotNil(center.peekView)
        center.forgetPointer()
        XCTAssertNil(center.peekView)
        XCTAssertEqual(center.presentation, .idle)
    }

    // MARK: - Full screen, per display

    func testFullScreenOnOneDisplayHidesOnlyThatIsland() {
        center.fullscreenPanels = ["screen-2"]
        XCTAssertFalse(center.isSuppressed(panel: "screen-1"))
        XCTAssertTrue(center.isSuppressed(panel: "screen-2"))
        XCTAssertTrue(center.isSuppressed, "asked about no display in particular, something is hidden")
        XCTAssertTrue(center.fullscreenSuppressed)
        center.fullscreenPanels = []
        XCTAssertFalse(center.isSuppressed)
    }

    func testAWindowFillingTheDisplayCoversIt() {
        let plain = FullscreenMonitor.Screen(panelID: "screen-2", rect: CGRect(x: 1710, y: 0, width: 2560, height: 1440), top: 0)
        XCTAssertTrue(FullscreenMonitor.covers(plain, CGRect(x: 1710, y: 0, width: 2560, height: 1440), reportedFullScreen: false))
        XCTAssertFalse(FullscreenMonitor.covers(plain, CGRect(x: 1710, y: 25, width: 2560, height: 1415), reportedFullScreen: false),
                       "a window zoomed under the menu bar is not full screen")
    }

    func testOnANotchedDisplayAFullScreenWindowStopsBelowTheHousing() {
        let notched = FullscreenMonitor.Screen(panelID: "screen-1", rect: CGRect(x: 0, y: 0, width: 1710, height: 1107), top: 37)
        let belowHousing = CGRect(x: 0, y: 37, width: 1710, height: 1070)
        XCTAssertTrue(FullscreenMonitor.covers(notched, belowHousing, reportedFullScreen: true))
        XCTAssertFalse(FullscreenMonitor.covers(notched, belowHousing, reportedFullScreen: false),
                       "the same frame is an ordinary window zoomed under the menu bar unless the app says otherwise")
        XCTAssertTrue(FullscreenMonitor.covers(notched, CGRect(x: 0, y: 0, width: 1710, height: 1107), reportedFullScreen: false),
                      "a window over the whole display, housing and all, is full screen whatever it says")
    }

    func testADisplayGoingFullScreenTakesOnlyItsOwnInteraction() {
        // The film is on screen-2; the panel is open on screen-1.
        XCTAssertFalse(FullscreenMonitor.forgetsInteraction(newlyCovered: ["screen-2"], hover: nil, drag: nil, isOpen: true, openPanel: "screen-1"))
        XCTAssertTrue(FullscreenMonitor.forgetsInteraction(newlyCovered: ["screen-2"], hover: nil, drag: nil, isOpen: true, openPanel: "screen-2"))
        XCTAssertTrue(FullscreenMonitor.forgetsInteraction(newlyCovered: ["screen-2"], hover: "screen-2", drag: nil, isOpen: false, openPanel: nil))
        XCTAssertTrue(FullscreenMonitor.forgetsInteraction(newlyCovered: ["screen-2"], hover: nil, drag: nil, isOpen: true, openPanel: nil),
                      "open on every display, it goes when any of them is covered")
        XCTAssertFalse(FullscreenMonitor.forgetsInteraction(newlyCovered: [], hover: "screen-2", drag: nil, isOpen: true, openPanel: nil),
                       "nothing new covered, nothing to forget")
    }
}
