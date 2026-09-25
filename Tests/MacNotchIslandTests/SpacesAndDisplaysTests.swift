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
                                                       fullScreenFrames: nil),
                       ["screen-2"], "the film is still full screen, whoever is in front")
    }

    func testAccessibilityIsAskedOnlyOfAnAppWithAWindowThatCouldBeFullScreen() {
        let windows = [FullscreenMonitor.Window(pid: 30, frame: safariWindow),
                       FullscreenMonitor.Window(pid: 40, frame: belowTheHousing),
                       FullscreenMonitor.Window(pid: 40, frame: belowTheHousing)]
        var asked: [pid_t] = []
        let covered = FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen, externalScreen],
                                                      fullScreenFrames: { pid in
            asked.append(pid)
            return pid == 40 ? [self.belowTheHousing] : []
        })
        XCTAssertEqual(covered, ["screen-1"])
        XCTAssertEqual(asked, [40], "once, and never Safari, whose ordinary window could not be full screen")

        asked = []
        let zoomed = FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen],
                                                     fullScreenFrames: { pid in
            asked.append(pid)
            return []
        })
        XCTAssertEqual(zoomed, [], "the app says the window is only zoomed, and the app is believed")
        XCTAssertEqual(asked, [40])
    }

    func testWithoutAccessibilityTheNotchedDisplayIsCoveredOnceItsMenuBarHasGone() {
        let windows = [FullscreenMonitor.Window(pid: 40, frame: belowTheHousing)]
        let bar = CGRect(x: 0, y: 0, width: 1710, height: 37)
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [bar], screens: [notchedScreen], fullScreenFrames: nil),
                       [], "zoomed under a menu bar that is still there")
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [notchedScreen], fullScreenFrames: nil),
                       ["screen-1"], "it used never to count at all without Accessibility")
        var noMenuBar = notchedScreen
        noMenuBar.hasMenuBar = false
        XCTAssertEqual(FullscreenMonitor.coveredPanels(windows: windows, menuBars: [], screens: [noMenuBar], fullScreenFrames: nil),
                       [], "a display that never has a menu bar cannot say anything by lacking one")
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
                                      FullscreenMonitor.Window(pid: 30, frame: safariWindow)],
                       "every app's ordinary windows, not ours, the Finder's, the Dock's, a palette or one nobody can see")
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

    func testANotchedIslandIsNotRebuiltForTheMenuBarMoving() {
        // As tall as the housing wherever the menu bar is: a monitor plugged in and given the
        // menu bar is no reason to tear the MacBook's island down.
        let builtIn = CGSize(width: 1512, height: 982)
        XCTAssertEqual(NotchPanel.displayKey(number: "1", size: builtIn, safeAreaTop: 32, isPrimary: true),
                       NotchPanel.displayKey(number: "1", size: builtIn, safeAreaTop: 32, isPrimary: false))
    }

    func testADisplayGoingFullScreenTakesOnlyItsOwnInteraction() {
        // The film is on screen-2; the panel is open on screen-1.
        XCTAssertFalse(FullscreenMonitor.forgetsInteraction(newlyCovered: ["screen-2"], hover: nil, drag: nil, isOpen: true, openPanel: "screen-1", allCovered: false))
        XCTAssertTrue(FullscreenMonitor.forgetsInteraction(newlyCovered: ["screen-2"], hover: nil, drag: nil, isOpen: true, openPanel: "screen-2", allCovered: false))
        XCTAssertTrue(FullscreenMonitor.forgetsInteraction(newlyCovered: ["screen-2"], hover: "screen-2", drag: nil, isOpen: false, openPanel: nil, allCovered: false))
        XCTAssertTrue(FullscreenMonitor.forgetsInteraction(newlyCovered: ["screen-2"], hover: nil, drag: nil, isOpen: true, openPanel: nil, allCovered: true),
                      "open on every display, it goes when every one of them is covered")
        XCTAssertFalse(FullscreenMonitor.forgetsInteraction(newlyCovered: [], hover: "screen-2", drag: nil, isOpen: true, openPanel: nil, allCovered: true),
                       "nothing new covered, nothing to forget")
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
        XCTAssertFalse(FullscreenMonitor.forgetsInteraction(newlyCovered: ["b"], hover: nil, drag: nil, isOpen: true, openPanel: nil, allCovered: false))
        XCTAssertTrue(FullscreenMonitor.forgetsInteraction(newlyCovered: ["b"], hover: nil, drag: nil, isOpen: true, openPanel: nil, allCovered: true))
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
