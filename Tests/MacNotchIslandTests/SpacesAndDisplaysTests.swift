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
