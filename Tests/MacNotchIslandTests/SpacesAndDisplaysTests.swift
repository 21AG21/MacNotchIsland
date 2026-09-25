import XCTest
import SwiftUI
@testable import MacNotchIsland

/// The rules behind the island's dealings with Spaces, displays and the mouse: what the panel
/// lets through, which island shows what was opened, when an app coming forward is the user
/// leaving, which display a full-screen app takes with it, when the island's own space may
/// show, and when a change of displays rebuilds the panels.
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
        XCTAssertTrue(NotchPanel.passesThrough(onIsland: true, engaged: false, suppressed: true, hold: .pressHere))
    }

    func testWhoseTheHeldButtonIsDependsOnWhereItWentDown() {
        XCTAssertEqual(NotchPanel.hold(buttonsDown: false, pressBeganHere: true, dragBegan: true), .buttonsUp)
        XCTAssertEqual(NotchPanel.hold(buttonsDown: true, pressBeganHere: true, dragBegan: false), .pressHere)
        XCTAssertEqual(NotchPanel.hold(buttonsDown: true, pressBeganHere: true, dragBegan: true), .carryingOut)
        XCTAssertEqual(NotchPanel.hold(buttonsDown: true, pressBeganHere: false, dragBegan: false), .fromElsewhere,
                       "a button held while the window happens to be solid is not a press that began here")
        XCTAssertEqual(NotchPanel.hold(buttonsDown: true, pressBeganHere: false, dragBegan: true), .fromElsewhere,
                       "the Finder's drag writes the drag pasteboard too, and is still the Finder's")
    }

    func testAFileCarriedAcrossTheIslandFromElsewhereIsLetThroughOffTheOutline() {
        // From the Desktop, across the notch, to a window near the top of the screen: the
        // canvas under the notch took the drop and did nothing with it.
        XCTAssertTrue(NotchPanel.passesThrough(onIsland: false, engaged: false, suppressed: false, hold: .fromElsewhere))
        // A stale slider flag does not lock the window against somebody else's drag either.
        XCTAssertTrue(NotchPanel.passesThrough(onIsland: false, engaged: true, suppressed: false, hold: .fromElsewhere))
        XCTAssertFalse(NotchPanel.passesThrough(onIsland: true, engaged: false, suppressed: false, hold: .fromElsewhere),
                       "over the outline the window is solid, or the shelf's well is no drop destination")
    }

    func testSomethingDraggedOutOfTheIslandIsLetThroughOffTheOutline() {
        // A shelf file, a clipboard row, a screenshot: the shelf's drag sets the slider flag
        // to keep the panel, and that must not keep the canvas from the window it is going to.
        XCTAssertTrue(NotchPanel.passesThrough(onIsland: false, engaged: true, suppressed: false, hold: .carryingOut))
        XCTAssertFalse(NotchPanel.passesThrough(onIsland: true, engaged: true, suppressed: false, hold: .carryingOut),
                       "brought back over the island, it can be dropped there")
    }

    func testAPressThatBeganOnTheIslandKeepsTheWindowOffIt() {
        // A slider run past the edge, the button still down on nothing.
        XCTAssertFalse(NotchPanel.passesThrough(onIsland: false, engaged: false, suppressed: false, hold: .pressHere))
    }

    func testADragFromElsewhereOpensNoPeek() {
        XCTAssertFalse(NotchPanel.reportsHover(onIsland: true, wasOnIsland: false, pointerMoved: true, hold: .fromElsewhere),
                       "a file carried across the pill opened the peek a quarter of a second later")
        XCTAssertTrue(NotchPanel.reportsHover(onIsland: true, wasOnIsland: false, pointerMoved: true, hold: .buttonsUp))
        XCTAssertTrue(NotchPanel.reportsHover(onIsland: false, wasOnIsland: true, pointerMoved: true, hold: .fromElsewhere),
                      "leaving is always told")
        XCTAssertFalse(NotchPanel.reportsHover(onIsland: true, wasOnIsland: false, pointerMoved: false, hold: .buttonsUp),
                       "an island that widened under a pointer that did not move is not being pointed at")
        XCTAssertTrue(NotchPanel.reportsHover(onIsland: false, wasOnIsland: true, pointerMoved: false, hold: .pressHere))
        XCTAssertFalse(NotchPanel.reportsHover(onIsland: true, wasOnIsland: true, pointerMoved: true, hold: .buttonsUp),
                       "only a change is news")
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

    /// On out of the box wherever the island floats, the watch read every window on the Mac
    /// every two seconds on every iMac and Mac mini, for a film that was not playing. Going
    /// full screen, an app coming forward and one quitting are heard as they happen; the timer
    /// is quick while something is covered, to see it uncovered, and for a few seconds after
    /// each event, for the display-sized window that arrives behind it.
    func testTheFullScreenWatchPollsQuicklyWhileSomethingIsCoveredAndJustAfterAnEvent() {
        let settled = FullscreenMonitor.settle + 1
        let covered = FullscreenMonitor.pollInterval(anyCovered: true, sinceEvent: settled, multiplier: 1)
        let idle = FullscreenMonitor.pollInterval(anyCovered: false, sinceEvent: settled, multiplier: 1)
        XCTAssertEqual(covered, 2, "a film ending brings the island back within a couple of seconds")
        XCTAssertGreaterThanOrEqual(idle, 5 * covered, "with nothing covered, the list is read rarely")
        XCTAssertLessThanOrEqual(idle, 30, "but a window no event announces is still seen within half a minute")
        XCTAssertEqual(FullscreenMonitor.pollInterval(anyCovered: false, sinceEvent: .infinity, multiplier: 1), idle,
                       "no event heard since the watch started")

        XCTAssertEqual(FullscreenMonitor.pollInterval(anyCovered: false, sinceEvent: 0, multiplier: 1), covered,
                       "a game came forward: its display-sized window can be a few seconds behind it")
        XCTAssertEqual(FullscreenMonitor.pollInterval(anyCovered: false, sinceEvent: FullscreenMonitor.settle - 0.5, multiplier: 1),
                       covered)
        XCTAssertEqual(FullscreenMonitor.pollInterval(anyCovered: false, sinceEvent: FullscreenMonitor.settle, multiplier: 1), idle,
                       "and once it has had time to arrive, the slow pace again")
        XCTAssertGreaterThanOrEqual(FullscreenMonitor.settle / covered, 3, "several looks before settling")
        XCTAssertLessThanOrEqual(FullscreenMonitor.settle, idle, "never longer than the slow pace it stands in for")

        XCTAssertEqual(FullscreenMonitor.pollInterval(anyCovered: false, sinceEvent: settled, multiplier: 4), 4 * idle,
                       "and every pace backs off with the energy policy")
        XCTAssertEqual(FullscreenMonitor.pollInterval(anyCovered: true, sinceEvent: settled, multiplier: 2), 2 * covered)
        XCTAssertEqual(FullscreenMonitor.pollInterval(anyCovered: false, sinceEvent: 0, multiplier: 4), 4 * covered)
    }

    /// Readings run on a concurrent queue and land in the order they finish; one that waited on
    /// an app's Accessibility answer used to put back what an older window list said.
    func testAReadingOlderThanTheLastOneAppliedIsDropped() {
        XCTAssertTrue(FullscreenMonitor.isNewer(4, than: 3))
        XCTAssertFalse(FullscreenMonitor.isNewer(3, than: 4), "overtaken by a newer reading")
        XCTAssertFalse(FullscreenMonitor.isNewer(3, than: 3))
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

    /// Without Accessibility the app cannot be asked, and the display's menu bar speaks for it:
    /// a full-screen Space takes the menu bar away, and a zoomed window leaves it there.
    func testWithoutAccessibilityAMenuBarThatHasGoneStandsForTheAppsWord() {
        let notched = FullscreenMonitor.Screen(panelID: "screen-1", rect: CGRect(x: 0, y: 0, width: 1710, height: 1107), top: 37)
        let belowHousing = CGRect(x: 0, y: 37, width: 1710, height: 1070)
        XCTAssertTrue(FullscreenMonitor.covers(notched, belowHousing, reportedFullScreen: false, menuBarVisible: false))
        XCTAssertFalse(FullscreenMonitor.covers(notched, belowHousing, reportedFullScreen: false, menuBarVisible: true),
                       "a zoomed window, with the menu bar where it always is")
        let plain = FullscreenMonitor.Screen(panelID: "screen-2", rect: CGRect(x: 1710, y: 0, width: 2560, height: 1440), top: 0)
        XCTAssertFalse(FullscreenMonitor.covers(plain, CGRect(x: 1710, y: 25, width: 2560, height: 1415), reportedFullScreen: false,
                                                menuBarVisible: false),
                       "a display with no housing has nothing for a window to stop short of")
    }

    func testAMenuBarIsOnTheDisplayWhoseTopEdgeItRunsAlong() {
        let notched = FullscreenMonitor.Screen(panelID: "screen-1", rect: CGRect(x: 0, y: 0, width: 1710, height: 1107), top: 37)
        let bar = CGRect(x: 0, y: 0, width: 1710, height: 37)
        XCTAssertTrue(FullscreenMonitor.menuBarVisible(on: notched, menuBars: [bar]))
        XCTAssertFalse(FullscreenMonitor.menuBarVisible(on: notched, menuBars: [CGRect(x: 1710, y: 0, width: 2560, height: 25)]),
                       "the other display's menu bar is not this one's")
        XCTAssertFalse(FullscreenMonitor.menuBarVisible(on: notched, menuBars: [bar.offsetBy(dx: 0, dy: -37)]),
                       "slid up out of sight is gone")
        XCTAssertFalse(FullscreenMonitor.menuBarVisible(on: notched, menuBars: []))
    }

    // MARK: - Full screen, whoever's window it is

    private let notchedScreen = FullscreenMonitor.Screen(panelID: "screen-1", rect: CGRect(x: 0, y: 0, width: 1710, height: 1107), top: 37)
    private let externalScreen = FullscreenMonitor.Screen(panelID: "screen-2", rect: CGRect(x: 1710, y: 0, width: 2560, height: 1440), top: 0)
    private let belowTheHousing = CGRect(x: 0, y: 37, width: 1710, height: 1070)
    private let safariWindow = CGRect(x: 120, y: 80, width: 1200, height: 800)

    func testAFilmFullScreenOnTheExternalDisplayStaysCoveredWhenAnotherAppComesForward() {
        // The film is QuickTime's; Safari has just been clicked on the MacBook and is in front.
        let windows = [FullscreenMonitor.Window(pid: 30, frame: safariWindow),
                       FullscreenMonitor.Window(pid: 20, frame: externalScreen.rect)]
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                       frontmost: 30, fullScreenFrames: nil),
                       ["screen-2"], "the film is still full screen, whoever is in front")
    }

    func testAccessibilityIsAskedOnlyOfAnAppWithAWindowThatCouldBeFullScreen() {
        // Front to back: the app full screen on the MacBook is at the front of its display.
        let windows = [FullscreenMonitor.Window(pid: 40, frame: belowTheHousing),
                       FullscreenMonitor.Window(pid: 40, frame: belowTheHousing),
                       FullscreenMonitor.Window(pid: 30, frame: safariWindow)]
        var asked: [pid_t] = []
        let covered = FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                      frontmost: 30, fullScreenFrames: { pid in
            asked.append(pid)
            return pid == 40 ? [self.belowTheHousing] : []
        })
        XCTAssertEqual(covered, ["screen-1"])
        XCTAssertEqual(asked, [40], "once, and never Safari, whose ordinary window could not be full screen")

        asked = []
        let zoomed = FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen],
                                                     frontmost: 30, fullScreenFrames: { pid in
            asked.append(pid)
            return []
        })
        XCTAssertEqual(zoomed, [], "the app says the window is only zoomed, and the app is believed")
        XCTAssertEqual(asked, [40])
    }

    func testWithoutAccessibilityTheNotchedDisplayIsCoveredOnceItsMenuBarHasGone() {
        let windows = [FullscreenMonitor.Window(pid: 40, frame: belowTheHousing)]
        let bar = CGRect(x: 0, y: 0, width: 1710, height: 37)
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [bar], screens: [notchedScreen],
                                                       frontmost: 40, fullScreenFrames: nil),
                       [], "zoomed under a menu bar that is still there")
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen],
                                                       frontmost: 40, fullScreenFrames: nil),
                       ["screen-1"], "it used never to count at all without Accessibility")
        var noMenuBar = notchedScreen
        noMenuBar.hasMenuBar = false
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [noMenuBar],
                                                       frontmost: 40, fullScreenFrames: nil),
                       [], "a display that never has a menu bar cannot say anything by lacking one")
    }

    /// On a display with no housing, with the menu bar hiding itself and no Dock there, a window
    /// zoomed to fill the display has the display's very frame, and the island went every time
    /// one was zoomed. The app is asked, and only a window with a close button that is not in
    /// full screen is taken for zoomed.
    func testAWindowItsAppCallsZoomedDoesNotCoverTheDisplayItFills() {
        let windows = [FullscreenMonitor.Window(pid: 30, frame: externalScreen.rect, number: 7)]
        var asked: [CGWindowID] = []
        let zoomed = FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                     frontmost: 30, fullScreenFrames: { _ in [] }, zoomed: { window in
            asked.append(window.number)
            return true
        })
        XCTAssertEqual(zoomed, [], "Safari zoomed on the external display, its menu bar hidden")
        XCTAssertEqual(asked, [7])

        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                       frontmost: 30, fullScreenFrames: { _ in [] }, zoomed: { _ in false }),
                       ["screen-2"], "a film full screen, or a game's borderless window: covered")
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                       frontmost: 30, fullScreenFrames: nil),
                       ["screen-2"], "without Accessibility the frame is all there is, as before")
    }

    func testOnlyAWindowThatFillsItsDisplayIsAskedWhetherItIsZoomed() {
        let windows = [FullscreenMonitor.Window(pid: 30, frame: safariOnExternal, number: 1),
                       FullscreenMonitor.Window(pid: 40, frame: belowTheHousing, number: 2)]
        var asked = 0
        let covered = FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                      frontmost: 30, fullScreenFrames: { _ in [] }, zoomed: { _ in
            asked += 1
            return false
        })
        XCTAssertEqual(covered, [])
        XCTAssertEqual(asked, 0, "an ordinary window, and one below the housing that its app did not call full screen")
    }

    /// The app is asked about a window once, not on every reading, until the next event: going
    /// full screen changes the Space, and what the window said while zoomed must not outlive it.
    func testAWindowsAnswerIsKeptUntilTheNextEvent() {
        let answers = FullscreenMonitor.ZoomAnswers()
        let zoomedSafari = FullscreenMonitor.Window(pid: 30, frame: externalScreen.rect, number: 7)
        XCTAssertNil(answers.answer(for: zoomedSafari, epoch: 1))
        answers.remember(true, for: zoomedSafari, epoch: 1)
        XCTAssertEqual(answers.answer(for: zoomedSafari, epoch: 1), true)
        var moved = zoomedSafari
        moved.frame.origin.x += 40
        XCTAssertNil(answers.answer(for: moved, epoch: 1), "another frame is another question")

        XCTAssertNil(answers.answer(for: zoomedSafari, epoch: 2), "an event since: asked again")
        answers.remember(false, for: zoomedSafari, epoch: 2)
        answers.remember(true, for: zoomedSafari, epoch: 1)
        XCTAssertEqual(answers.answer(for: zoomedSafari, epoch: 2), false,
                       "a reading that started before the event does not put its answer back")

        let unnumbered = FullscreenMonitor.Window(pid: 30, frame: externalScreen.rect)
        answers.remember(true, for: unnumbered, epoch: 2)
        XCTAssertNil(answers.answer(for: unnumbered, epoch: 2), "nothing tells a window without a number from the next one")
    }

    // MARK: - Full screen, and only at the front

    private let safariOnExternal = CGRect(x: 1900, y: 200, width: 1200, height: 800)

    /// A utility that keeps a window the size of the external display behind everything else
    /// hid that display's island for as long as it ran.
    func testADisplaySizedWindowBehindAnotherAppsCoversNothing() {
        let windows = [FullscreenMonitor.Window(pid: 30, frame: safariOnExternal),
                       FullscreenMonitor.Window(pid: 70, frame: externalScreen.rect)]
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                       frontmost: 30, fullScreenFrames: nil),
                       [], "Safari is in front of it there")
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                       frontmost: nil, fullScreenFrames: nil),
                       [], "and so with nobody in particular in front")
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                       frontmost: 70, fullScreenFrames: nil),
                       ["screen-2"], "the app in front is what the user is in, wherever its window stands")
    }

    func testTheFindersWindowInFrontOfItIsInFrontOfIt() {
        // The Finder never covers a display, but it can stand in front of what would.
        let windows = [FullscreenMonitor.Window(pid: 2, frame: safariOnExternal, canCover: false),
                       FullscreenMonitor.Window(pid: 70, frame: externalScreen.rect)]
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [externalScreen],
                                                       frontmost: 2, fullScreenFrames: nil), [])
        XCTAssertEqual(FullscreenMonitor.contenders(on: externalScreen, among: [externalScreen], windows: windows, frontmost: 2), [],
                       "and is never a contender itself")
    }

    func testTheFrontOfADisplayIsTheFirstWindowThatShowsOnIt() {
        let windows = [FullscreenMonitor.Window(pid: 80, frame: CGRect(x: 1710, y: 0, width: 1, height: 1)),
                       FullscreenMonitor.Window(pid: 81, frame: CGRect(x: -5000, y: -5000, width: 500, height: 500)),
                       FullscreenMonitor.Window(pid: 30, frame: safariWindow),
                       FullscreenMonitor.Window(pid: 20, frame: externalScreen.rect),
                       FullscreenMonitor.Window(pid: 20, frame: safariOnExternal)]
        let both = [notchedScreen, externalScreen]
        XCTAssertEqual(FullscreenMonitor.contenders(on: externalScreen, among: both, windows: windows, frontmost: nil).map(\.pid), [20, 20],
                       "a point-wide window, one parked off every display and one on the other display are in front of nothing")
        XCTAssertEqual(FullscreenMonitor.contenders(on: notchedScreen, among: both, windows: windows, frontmost: nil).map(\.pid), [30])
        XCTAssertTrue(FullscreenMonitor.isOn(externalScreen, safariOnExternal))
        XCTAssertFalse(FullscreenMonitor.isOn(externalScreen, safariWindow))
    }

    /// A Safari window on the external display, against the shared edge, overhangs the MacBook
    /// by a few points. It was the MacBook's front, being first in the list with two points
    /// there, and the film full screen on the MacBook came out from under its island.
    func testAWindowOverhangingTheSharedEdgeIsInFrontOfItsOwnDisplayOnly() {
        let overhanging = CGRect(x: 1705, y: 100, width: 1200, height: 800)
        let windows = [FullscreenMonitor.Window(pid: 30, frame: overhanging),
                       FullscreenMonitor.Window(pid: 20, frame: notchedScreen.rect)]
        XCTAssertTrue(FullscreenMonitor.isOn(notchedScreen, overhanging), "five points of it do lie on the MacBook")
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                       frontmost: 30, fullScreenFrames: nil),
                       ["screen-1"], "Safari belongs to the external display, and the film is the MacBook's front")
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                       frontmost: nil, fullScreenFrames: nil),
                       ["screen-1"])

        // The same when the external display carries no island: it is still where Safari is.
        var bare = externalScreen
        bare.carriesIsland = false
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, bare],
                                                       frontmost: 30, fullScreenFrames: nil),
                       ["screen-1"])
        let filmThere = [FullscreenMonitor.Window(pid: 20, frame: externalScreen.rect)]
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: filmThere, menuBars: [], screens: [notchedScreen, bare],
                                                       frontmost: 20, fullScreenFrames: nil),
                       [], "a display with no island is never covered")
    }

    func testAWindowBelongsToTheDisplayHoldingItsCentreOrElseToTheOneWithMostOfIt() {
        let both = [notchedScreen, externalScreen]
        XCTAssertEqual(FullscreenMonitor.home(of: CGRect(x: 1705, y: 100, width: 1200, height: 800), among: both), "screen-2")
        XCTAssertEqual(FullscreenMonitor.home(of: CGRect(x: 600, y: 100, width: 1200, height: 800), among: both), "screen-1",
                       "the centre is on the MacBook, a few points of it on the external display")
        XCTAssertEqual(FullscreenMonitor.home(of: CGRect(x: 1000, y: 1000, width: 1000, height: 1000), among: both), "screen-2",
                       "centre below the MacBook, on no display: the external display has most of it")
        XCTAssertNil(FullscreenMonitor.home(of: CGRect(x: 1710, y: 0, width: 1, height: 1), among: both))
        XCTAssertNil(FullscreenMonitor.home(of: CGRect(x: -5000, y: -5000, width: 500, height: 500), among: both))
    }

    private func listed(pid: pid_t, owner: String, layer: Int = 0, name: String? = nil, bounds: CGRect,
                        alpha: Double = 1) -> [String: Any] {
        var entry: [String: Any] = [kCGWindowOwnerPID as String: pid,
                                    kCGWindowOwnerName as String: owner,
                                    kCGWindowLayer as String: layer,
                                    kCGWindowAlpha as String: alpha,
                                    kCGWindowBounds as String: bounds.dictionaryRepresentation]
        if let name { entry[kCGWindowName as String] = name }
        return entry
    }

    func testTheWindowListIsEveryAppsOrdinaryWindowsAndTheMenuBars() {
        let film = externalScreen.rect
        let bar = CGRect(x: 0, y: 0, width: 1710, height: 37)
        let otherBar = CGRect(x: 1710, y: 0, width: 2560, height: 25)
        let seen = FullscreenMonitor.windowList([
            listed(pid: 20, owner: "QuickTime Player", bounds: film),
            listed(pid: 30, owner: "Safari", bounds: safariWindow),
            listed(pid: 1, owner: "Notch Island", bounds: film),
            listed(pid: 2, owner: "Finder", bounds: film),
            listed(pid: 3, owner: "Dock", bounds: film),
            listed(pid: 4, owner: "Window Server", layer: 24, name: "Menubar", bounds: bar),
            // Another process's window names are withheld without Screen Recording.
            listed(pid: 4, owner: "Window Server", layer: 24, bounds: otherBar),
            listed(pid: 4, owner: "Window Server", layer: 24, name: "Backstop Menubar", bounds: bar),
            listed(pid: 50, owner: "Palette", layer: 3, bounds: film),
            listed(pid: 60, owner: "Ghost", bounds: film, alpha: 0),
        ], ignoring: [1, 2])
        XCTAssertEqual(seen.windows, [FullscreenMonitor.Window(pid: 20, frame: film),
                                      FullscreenMonitor.Window(pid: 30, frame: safariWindow),
                                      FullscreenMonitor.Window(pid: 1, frame: film, canCover: false),
                                      FullscreenMonitor.Window(pid: 2, frame: film, canCover: false)],
                       "every app's ordinary windows, in the list's order — ours and the Finder's for where they stand, "
                       + "never as what covers — and not the Dock's, a palette or one nobody can see")
        XCTAssertEqual(seen.menuBars, [bar, otherBar])
    }

    // MARK: - The island's own space

    func testTheIslandsSpaceIsNeverShownOverTheLockScreenOrAScreenSaver() {
        XCTAssertTrue(IslandSpace.shows(locked: false, screenSaverRunning: false))
        XCTAssertFalse(IslandSpace.shows(locked: true, screenSaverRunning: false),
                       "a space made at the lock screen — the app launched there by a script's alert — starts hidden")
        XCTAssertFalse(IslandSpace.shows(locked: false, screenSaverRunning: true),
                       "nor over a screen saver that asks for no password")
        XCTAssertFalse(IslandSpace.shows(locked: true, screenSaverRunning: true))
    }

    func testAMenusWindowsJoinTheSpaceAndNothingBelowTheIslandDoes() {
        let me: pid_t = 100
        let level = NotchPanel.islandLevel.rawValue
        func window(_ number: Int, pid: pid_t = 100, layer: Int) -> [String: Any] {
            [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer]
        }
        let list = [window(1, layer: level),          // the panel itself
                    window(2, layer: 101),            // the right-click menu
                    window(3, layer: 101),            // a submenu
                    window(4, layer: 0),              // Settings
                    window(5, layer: 25),             // the status item
                    window(6, pid: 200, layer: 101)]  // another app's menu
        XCTAssertEqual(IslandSpace.menuWindowNumbers(in: list, pid: me, above: level), [2, 3])
    }

    // MARK: - Which displays the panels were built for

    func testMovingTheMenuBarToAnotherDisplayRebuildsTheFloatingIsland() {
        let external = CGSize(width: 2560, height: 1440)
        let builtIn = CGSize(width: 1512, height: 982)
        let before: Set = [NotchPanel.displayKey(number: "2", size: external, safeAreaTop: 0, isPrimary: true),
                           NotchPanel.displayKey(number: "1", size: builtIn, safeAreaTop: 32, isPrimary: false)]
        let after: Set = [NotchPanel.displayKey(number: "2", size: external, safeAreaTop: 0, isPrimary: false),
                          NotchPanel.displayKey(number: "1", size: builtIn, safeAreaTop: 32, isPrimary: true)]
        XCTAssertTrue(AppDelegate.displaysChanged(now: after, before: before),
                      "the floating pill hangs under a menu bar, or does not, by where the menu bar is")
        let again: Set = [NotchPanel.displayKey(number: "2", size: external, safeAreaTop: 0, isPrimary: true),
                          NotchPanel.displayKey(number: "1", size: builtIn, safeAreaTop: 32, isPrimary: false)]
        XCTAssertFalse(AppDelegate.displaysChanged(now: again, before: before), "nothing moved, nothing to rebuild")
    }

    /// The floating pill hangs under a menu bar that shows and at the top of a display whose
    /// menu bar hides itself, and the setting was read only when the panels were built:
    /// switching it left the pill where the old setting had put it until something else
    /// rebuilt them.
    func testTheMenuBarHidingItselfRebuildsTheFloatingIsland() {
        let external = CGSize(width: 2560, height: 1440)
        let shows = NotchPanel.displayKey(number: "2", size: external, safeAreaTop: 0, isPrimary: true, menuBarHides: false)
        let hides = NotchPanel.displayKey(number: "2", size: external, safeAreaTop: 0, isPrimary: true, menuBarHides: true)
        XCTAssertTrue(AppDelegate.displaysChanged(now: [hides], before: [shows]), "switched on: rebuilt")
        XCTAssertTrue(AppDelegate.displaysChanged(now: [shows], before: [hides]), "and off again")
        XCTAssertEqual(shows, NotchPanel.displayKey(number: "2", size: external, safeAreaTop: 0, isPrimary: true),
                       "a menu bar that stays is the key as it always was")
        let builtIn = CGSize(width: 1512, height: 982)
        XCTAssertEqual(NotchPanel.displayKey(number: "1", size: builtIn, safeAreaTop: 32, isPrimary: true, menuBarHides: true),
                       NotchPanel.displayKey(number: "1", size: builtIn, safeAreaTop: 32, isPrimary: true, menuBarHides: false),
                       "a notched island is as tall as the housing whatever the menu bar does")
    }

    func testANotchedIslandIsNotRebuiltForTheMenuBarMoving() {
        // As tall as the housing wherever the menu bar is: a monitor plugged in and given the
        // menu bar is no reason to tear the MacBook's island down.
        let builtIn = CGSize(width: 1512, height: 982)
        XCTAssertEqual(NotchPanel.displayKey(number: "1", size: builtIn, safeAreaTop: 32, isPrimary: true),
                       NotchPanel.displayKey(number: "1", size: builtIn, safeAreaTop: 32, isPrimary: false))
    }

    func testADisplayGoingFullScreenTakesOnlyItsOwnInteraction() {
        // The film is on screen-2; the panel is open on screen-1.
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["screen-2"], hover: nil, drag: nil, isOpen: true, openPanel: "screen-1", allCovered: false),
                       .nothing)
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["screen-2"], hover: nil, drag: nil, isOpen: true, openPanel: "screen-2", allCovered: false),
                       .closeAll)
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["screen-2"], hover: "screen-2", drag: nil, isOpen: false, openPanel: nil, allCovered: false),
                       .forgetPointer)
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["screen-2"], hover: nil, drag: "screen-2", isOpen: false, openPanel: nil, allCovered: false),
                       .forgetPointer)
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["screen-2"], hover: nil, drag: nil, isOpen: true, openPanel: nil, allCovered: true),
                       .closeAll, "open on every display, it goes when every one of them is covered")
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: [], hover: "screen-2", drag: nil, isOpen: true, openPanel: nil, allCovered: true),
                       .nothing, "nothing new covered, nothing to forget")
    }

    func testThePointerOnTheCoveredDisplayLeavesThePanelPinnedOnTheOther() {
        // The pointer was resting on the external display's island as its film went full
        // screen; the panel pinned on the MacBook was closed with it.
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["screen-2"], hover: "screen-2", drag: nil, isOpen: true, openPanel: "screen-1", allCovered: false),
                       .forgetPointer)
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["screen-2"], hover: nil, drag: "screen-2", isOpen: true, openPanel: "screen-1", allCovered: false),
                       .forgetPointer, "a drag over there too")
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["screen-2"], hover: "screen-2", drag: nil, isOpen: true, openPanel: nil, allCovered: false),
                       .forgetPointer, "open everywhere, it stays on the display that is still showing")
    }

    func testForgettingOneIslandsPointerLeavesTheOthers() {
        center.tap(panel: "screen-1")
        center.setHovering(true, panel: "screen-2")
        let exp = expectation(description: "hovering")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(center.hoverPanel, "screen-2")
        center.setDragTargeted(true, panel: "screen-1")

        center.forgetPointer(on: ["screen-2"])
        XCTAssertNil(center.hoverPanel, "the pointer on the covered display is forgotten")
        XCTAssertEqual(center.dragPanel, "screen-1", "the drag over the other display is not")
        XCTAssertTrue(center.openHere("screen-1"), "and the panel pinned there stays")

        center.forgetPointer(on: ["screen-1"])
        XCTAssertNil(center.dragPanel)
        XCTAssertTrue(center.isOpen, "forgetting the pointer closes nothing")
        center.clearInteraction(on: ["screen-1"])
        XCTAssertFalse(center.isOpen, "closing is the other decision")
        XCTAssertNil(center.openPanel)
    }
}

/// The interaction rules the pointer and the keyboard live by.
final class PointerAndKeyboardTests: XCTestCase {
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

    func testRepeatingAHoverRequestDoesNotRestartItsTimer() {
        Preferences.shared.hoverDelay = 0.3
        center.setHovering(true, panel: "screen-1")
        settle(0.15)
        center.setHovering(true, panel: "screen-1")   // the pointer moved; the panel says so again
        settle(0.25)
        // 0.4 s after the first request: had the second re-armed the timer, this would still
        // be nil for another 0.15 s.
        XCTAssertEqual(center.hoverPanel, "screen-1")
    }

    func testClosingUnderThePointerShowsNoPeekUntilItHasLeft() {
        center.setHovering(true, panel: "screen-1")
        settle(0.1)
        guard case .panel = center.presentation(for: "screen-1") else { return XCTFail("a peek") }
        center.pinPeek(panel: "screen-1")
        XCTAssertTrue(center.isOpen)

        center.collapse(reason: "escape")
        XCTAssertEqual(center.presentation(for: "screen-1"), .idle, "closed, although the pointer is still on it")
        // The pointer is still there and the view says so again: no peek.
        center.setHovering(true, panel: "screen-1")
        settle(0.1)
        XCTAssertEqual(center.presentation(for: "screen-1"), .idle)
        // It leaves and comes back: a peek again.
        center.setHovering(false, panel: "screen-1")
        settle(ActivityCenter.hoverExitGrace + 0.1)
        center.setHovering(true, panel: "screen-1")
        settle(0.1)
        guard case .panel = center.presentation(for: "screen-1") else { return XCTFail("peeks again after leaving") }
    }

    func testAStopOnACardClosesItUnderThePointer() {
        center.upsert(IslandActivity(id: "t", kind: .timer, content: .custom(CustomActivity(title: "T")), priority: 70))
        center.setHovering(true, panel: "screen-1")
        settle(0.1)
        center.pinPeek(panel: "screen-1")
        XCTAssertEqual(center.openView, .activity(id: "t"))
        center.end(id: "t")
        XCTAssertNil(center.openView)
        XCTAssertEqual(center.presentation(for: "screen-1"), .idle, "nothing drawn back under the pointer")
        XCTAssertEqual(center.navigationDirection, 0)
    }

    func testAClickOnAControlPinsButDoesNotInviteTheKeyboard() {
        Preferences.shared.panelKeysEnabled = true
        // A section nobody types into, so only the invitation decides.
        UserDefaults.standard.set(HomeSection.music.rawValue, forKey: GestureRouter.homeTabKey)
        center.setHovering(true, panel: "screen-1")
        settle(0.1)
        center.pinPeek(panel: "screen-1")
        XCTAssertTrue(center.isOpen)
        XCTAssertFalse(center.keyboardInvited)
        XCTAssertFalse(center.wantsPanelKeyboard, "the hand that clicked pause is going back to its typing")
        center.tap(panel: "screen-1")
        XCTAssertTrue(center.keyboardInvited, "a click on the island's body asks for it")
        XCTAssertTrue(center.wantsPanelKeyboard)
        center.collapse()
        XCTAssertFalse(center.keyboardInvited, "the invitation ends with the panel")
    }

    func testTheShortcutAndTabInviteTheKeyboard() {
        Preferences.shared.panelKeysEnabled = true
        center.toggle()
        XCTAssertTrue(center.keyboardInvited)
        center.collapse()
        center.cycleView(forward: true)
        XCTAssertTrue(center.keyboardInvited)
    }

    func testTabFromClosedOpensStraightOn() {
        center.cycleView(forward: true)
        XCTAssertTrue(center.isOpen)
        XCTAssertEqual(center.navigationDirection, 0, "an open, not a step: no slide from the side")
        center.cycleView(forward: true)
        XCTAssertEqual(center.navigationDirection, 1, "the next one is a step")
    }

    func testAHiddenIslandOpensNothing() {
        center.fullscreenPanels = ["screen-1"]
        center.tap(panel: "screen-1")
        XCTAssertFalse(center.isOpen)
        center.toggle()
        XCTAssertFalse(center.isOpen, "the shortcut opens nothing invisible")
        XCTAssertFalse(center.wantsPanelKeyboard)
        center.fullscreenPanels = []
        center.toggle()
        XCTAssertTrue(center.isOpen)
    }

    func testAScriptsDurationIsTakenAsItIs() {
        Preferences.shared.alertDuration = 6
        let alert = IslandActivity(id: "a", kind: .custom, content: .custom(CustomActivity(title: "A")), priority: 70)
        center.showAlert(alert, duration: 0.2, exact: true, haptic: false)
        settle(0.5)
        XCTAssertNil(center.alert, "gone after the 0.2 s it asked for, not the 0.67 s the slider would make of it")
        Preferences.shared.alertDuration = ActivityCenter.standardAlertDuration
    }

    func testAHUDOverALiveActivityKeepsItsBubble() {
        center.upsert(IslandActivity(id: "music", kind: .nowPlaying, content: .custom(CustomActivity(title: "M")), priority: 60))
        center.upsert(IslandActivity(id: "timer", kind: .timer, content: .custom(CustomActivity(title: "T")), priority: 70))
        guard case .compact(_, let before) = center.presentation, before != nil else { return XCTFail("two live: a bubble") }
        // Caps Lock is the one custom-content alert that ranks as a key-press HUD.
        let hud = IslandActivity(id: "capslock", kind: .hud, content: .custom(CustomActivity(title: "Caps Lock")), priority: 80)
        center.showAlert(hud, duration: 5, haptic: false)
        guard case .compact(let shown, let bubble) = center.presentation else { return XCTFail("the HUD shows compact") }
        XCTAssertEqual(shown.id, "capslock")
        XCTAssertNotNil(IslandLayout.activityUnder(hud, center: center), "the live activity's glyph stays under it")
        XCTAssertNotNil(bubble, "and so does its bubble")
    }

    func testThePanelViewForTheShelfCase() {
        XCTAssertEqual(IslandPresentation.shelf.panelView, .home(tab: HomeSection.shelf.rawValue))
        XCTAssertEqual(IslandPresentation.panel(.home(tab: "music")).panelView, .home(tab: "music"))
        XCTAssertNil(IslandPresentation.idle.panelView)
    }

    // MARK: - A click just after the island grew

    func testAClickJustAfterTheIslandGrewGoesToTheBody() {
        // The peek grew a quarter of a second after the pointer arrived, and the click aimed at
        // the timer's digits landed on the slots that start ten points past the notch.
        XCTAssertTrue(NotchPanel.clickGoesToBody(sinceGrew: 0.1, clickCount: 1, sinceOpened: 60, doubleClickInterval: 0.5))
        XCTAssertTrue(NotchPanel.clickGoesToBody(sinceGrew: NotchPanel.growthGuard, clickCount: 1, sinceOpened: 60,
                                                 doubleClickInterval: 0.5))
        XCTAssertFalse(NotchPanel.clickGoesToBody(sinceGrew: NotchPanel.growthGuard + 0.05, clickCount: 1, sinceOpened: 60,
                                                  doubleClickInterval: 0.5), "a click on a panel that has settled is its own")
        XCTAssertFalse(NotchPanel.clickGoesToBody(sinceGrew: .infinity, clickCount: 1, sinceOpened: 60, doubleClickInterval: 0.5),
                       "another display's island grew")
        XCTAssertFalse(NotchPanel.clickGoesToBody(sinceGrew: -1, clickCount: 1, sinceOpened: 60, doubleClickInterval: 0.5),
                       "a clock gone backwards is no growth")
    }

    func testTheSecondClickOfADoubleClickThatOpenedThePanelGoesToTheBody() {
        // The first click opened the pill's panel on its mouse-up, which is when it grew; the
        // second landed a moment later on the band's slots, where the pill's digits had been.
        XCTAssertTrue(NotchPanel.clickGoesToBody(sinceGrew: 0.4, clickCount: 2, sinceOpened: 0.4, doubleClickInterval: 0.5))
        XCTAssertTrue(NotchPanel.clickGoesToBody(sinceGrew: 1.2, clickCount: 2, sinceOpened: 1.25, doubleClickInterval: 2),
                      "however slow the double click is set to be")
        XCTAssertFalse(NotchPanel.clickGoesToBody(sinceGrew: 0.6, clickCount: 2, sinceOpened: 0.6, doubleClickInterval: 0.5),
                       "past the double-click interval it is a click of its own")
        XCTAssertFalse(NotchPanel.clickGoesToBody(sinceGrew: 0.4, clickCount: 1, sinceOpened: 0.4, doubleClickInterval: 0.5))
    }

    func testADoubleClickOnAPeekAlreadyShowingKeepsItsSecondClick() {
        // Its first click only pinned a peek that had been up for a while — nothing grew — so
        // the second is the double click a shelf file opens on.
        XCTAssertFalse(NotchPanel.clickGoesToBody(sinceGrew: 3, clickCount: 2, sinceOpened: 0.2, doubleClickInterval: 0.5))
    }

    func testAPeekArrivingIsGrowthAndPinningItIsNot() {
        center.setHovering(true, panel: "screen-1")
        settle(0.1)
        guard case .panel = center.presentation(for: "screen-1") else { return XCTFail("a peek") }
        XCTAssertLessThan(center.sinceGrew(on: "screen-1"), 1)
        XCTAssertEqual(center.sinceGrew(on: "screen-2"), .infinity, "the other display's island grew nothing")
        let grew = center.grewAt
        center.pinPeek(panel: "screen-1")
        XCTAssertTrue(center.isOpen)
        XCTAssertEqual(center.grewAt, grew, "the peek was already the panel; pinning it moves nothing")
        XCTAssertGreaterThan(center.sinceGrew(on: "screen-1", now: center.openedAt), 0,
                             "so the second click of a double click that pinned it is its own")
    }

    func testAClickThatOpensThePillGrowsIt() {
        center.upsert(IslandActivity(id: "t", kind: .timer, content: .custom(CustomActivity(title: "T")), priority: 70))
        center.tap(panel: "screen-1")
        XCTAssertEqual(center.openView, .activity(id: "t"))
        XCTAssertGreaterThanOrEqual(center.grewAt, center.openedAt, "grown at the open, which the double-click rule reads")
        XCTAssertEqual(center.grewOn, "screen-1")
        let grew = center.grewAt
        center.cycleView(forward: true)
        XCTAssertEqual(center.grewAt, grew, "a step changes what the panel shows, not its size")
    }

    func testTheIslandDoesNotGrowUnderAPointerThatOpensNothing() {
        Preferences.shared.hoverToExpand = false
        center.upsert(IslandActivity(id: "t", kind: .timer, content: .custom(CustomActivity(title: "T")), priority: 70))
        center.setHovering(true, panel: "screen-1")
        settle(0.1)
        XCTAssertEqual(center.hoverPanel, "screen-1")
        XCTAssertGreaterThan(center.sinceGrew(on: "screen-1"), NotchPanel.growthGuard)
        Preferences.shared.hoverToExpand = true
    }

    // MARK: - The keyboard after a close

    func testOnlyAKeyboardCloseHandsTheKeyboardBackAtOnce() {
        XCTAssertTrue(NotchPanel.releasesKeyAtOnce(reason: "escape"))
        XCTAssertTrue(NotchPanel.releasesKeyAtOnce(reason: "shortcut"))
        XCTAssertFalse(NotchPanel.releasesKeyAtOnce(reason: "click outside"), "the click has already moved key status")
        XCTAssertFalse(NotchPanel.releasesKeyAtOnce(reason: "close button"))
        XCTAssertFalse(NotchPanel.releasesKeyAtOnce(reason: nil), "a close that did not go through collapse waits")
    }

    func testTheCentreRemembersHowThePanelLastClosed() {
        center.toggle()
        XCTAssertTrue(center.isOpen)
        XCTAssertNil(center.closeReason)
        center.toggle()
        XCTAssertFalse(center.isOpen)
        XCTAssertEqual(center.closeReason, "shortcut", "the reason the shortcut gives is one the panel knows")
        XCTAssertTrue(NotchPanel.releasesKeyAtOnce(reason: center.closeReason))
        center.toggle()
        XCTAssertNil(center.closeReason, "forgotten when something opens again")
        center.collapse(reason: "click outside")
        XCTAssertFalse(NotchPanel.releasesKeyAtOnce(reason: center.closeReason))
    }
}

/// The rules an island on each of two displays lives by, and the pointer's edge cases.
final class TwoDisplayTests: XCTestCase {
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

    func testHiddenMeansEveryIslandThereIs() {
        XCTAssertFalse(ActivityCenter.allHidden(live: ["a", "b"], covered: ["b"]), "a film on one display leaves the other")
        XCTAssertTrue(ActivityCenter.allHidden(live: ["a", "b"], covered: ["a", "b"]))
        XCTAssertTrue(ActivityCenter.allHidden(live: [], covered: ["b"]), "with no islands known, any cover counts")
        XCTAssertFalse(ActivityCenter.allHidden(live: ["a"], covered: []))
    }

    func testTheShortcutOpensWhileOnlyTheOtherDisplayIsCovered() {
        center.panelsRebuilt(["a", "b"])
        center.fullscreenPanels = ["b"]
        XCTAssertFalse(center.isSuppressed, "the island on a is showing")
        center.toggle()
        XCTAssertTrue(center.isOpen)
        guard case .panel = center.presentation(for: "a") else { return XCTFail("open on the uncovered island") }
        XCTAssertTrue(center.isSuppressed(panel: "b"))
    }

    func testAnIslandThatIsGoneNoLongerHoldsTheOpenView() {
        center.tap(panel: "gone")
        XCTAssertEqual(center.openPanel, "gone")
        center.panelsRebuilt(["a"])
        XCTAssertNil(center.openPanel, "opened everywhere rather than drawn nowhere")
        XCTAssertTrue(center.isOpen)
    }

    func testAClickOnTheOtherIslandIsNotAClickOnAnOpenPanel() {
        center.tap(panel: "a")
        XCTAssertEqual(center.openPanel, "a")
        XCTAssertTrue(center.openHere("a"))
        XCTAssertFalse(center.openHere("b"))
        XCTAssertTrue(center.openHere(nil))
        // A peek on b, then a click: b opens here rather than doing nothing.
        center.setHovering(true, panel: "b")
        settle(0.1)
        center.tap(panel: "b")
        XCTAssertTrue(center.openHere("b"))
    }

    func testAlertsShowOnTheIslandThePanelIsNotOn() {
        center.tap(panel: "a")
        let alert = IslandActivity(id: "battery", kind: .custom, content: .custom(CustomActivity(title: "B")), priority: 70)
        center.showAlert(alert, duration: 5, haptic: false)
        guard case .compact(let shown, _) = center.presentation(for: "b") else { return XCTFail("the alert shows on b") }
        XCTAssertEqual(shown.id, "battery")
        guard case .panel = center.presentation(for: "a") else { return XCTFail("the panel stays on a") }
    }

    func testAClickThatOpensNothingDoesNotInviteTheKeyboard() {
        Preferences.shared.panelKeysEnabled = true
        let hud = IslandActivity(id: "capslock", kind: .hud, content: .custom(CustomActivity(title: "Caps Lock")), priority: 80)
        center.showAlert(hud, duration: 5, haptic: false)
        center.tap(panel: "a")
        XCTAssertFalse(center.isOpen)
        XCTAssertFalse(center.keyboardInvited, "a click on a key-press HUD asked for nothing")
    }

    func testClosingWhileThePointerIsAlreadyLeavingSuppressesNoPeek() {
        center.setHovering(true, panel: "a")
        settle(0.1)
        center.pinPeek(panel: "a")
        XCTAssertTrue(center.isOpen)
        // The pointer leaves; its grace is running when Escape lands.
        center.setHovering(false, panel: "a")
        center.collapse(reason: "escape")
        XCTAssertNil(center.hoverPanel)
        // The pointer comes back: a peek, straight away — nothing was waiting it out.
        center.setHovering(true, panel: "a")
        settle(0.1)
        guard case .panel = center.presentation(for: "a") else { return XCTFail("peeks again at once") }
    }

    func testADisplayGoingFullScreenClosesAnEverywherePanelOnlyWhenEveryIslandIsCovered() {
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["b"], hover: nil, drag: nil, isOpen: true, openPanel: nil, allCovered: false),
                       .nothing)
        XCTAssertEqual(FullscreenMonitor.forgetting(newlyCovered: ["b"], hover: nil, drag: nil, isOpen: true, openPanel: nil, allCovered: true),
                       .closeAll)
    }

    func testTheOutlineCanLeaveTheBubbleOut() {
        let notched = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107), notchWidth: 185, notchHeight: 33.5,
                                    hasPhysicalNotch: true, menuBarHeight: 33.5)
        let a = IslandActivity(id: "a", kind: .timer, content: .custom(CustomActivity(title: "A")), priority: 70)
        let b = IslandActivity(id: "b", kind: .custom, content: .custom(CustomActivity(title: "B")), priority: 60)
        let layout = IslandLayout.make(presentation: .compact(a, bubble: b), geometry: notched)
        XCTAssertTrue(layout.hasBubble)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 340)
        let bodyMaxX = bounds.midX + layout.bodyShift + layout.frameWidth / 2
        let onBubble = CGPoint(x: bodyMaxX + layout.bubbleGap + layout.bubbleDiameter / 2, y: layout.bubbleDiameter / 2)
        let withBubble = NotchHostingView<EmptyView>.outline(of: layout, in: bounds)
        let without = NotchHostingView<EmptyView>.outline(of: layout, in: bounds, includingBubble: false)
        XCTAssertTrue(withBubble.contains(onBubble), "a click on the bubble is a click")
        XCTAssertFalse(without.contains(onBubble), "a pointer resting on it is not a hover")
        XCTAssertTrue(without.contains(CGPoint(x: bounds.midX, y: 10)), "the body is in both")
    }
}
