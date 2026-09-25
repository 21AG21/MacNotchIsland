import AppKit
import Combine
import SwiftUI

/// A transparent panel that floats above the menu bar and full-screen apps, positioned over the
/// notch of its screen.
///
/// The window is as tall as the tallest thing the island can show, always, and only its width
/// follows the island's footprint: it widens the instant something opens (so the spring has room
/// to overshoot) and narrows back a moment after something closes. The window is transparent
/// to the mouse whenever the pointer is off the island (see `passesThrough`), so the menu bar
/// and the windows under the clear part stay clickable whatever size the window is.
///
/// The height used to follow the island too, and that is what broke the opening animation. A
/// window that grows in the same turn of the run loop as the state that opens the panel hands
/// SwiftUI a root that has already changed size when it lays the new state out; it committed
/// the island's box at its final height and then animated the contents inside it, so the
/// island appeared a hundred points below the notch and grew about its own middle. The close
/// never had the fault, because the shrink was always deferred until the spring had settled —
/// the container was still. Now the container is still on the way out as well.
final class NotchPanel: NSPanel {
    /// The height the window always has. Tall enough for the tallest card with its shadow, and
    /// never changed, for the reason above.
    static let canvasHeight: CGFloat = 340
    /// Room around the island at rest: enough for its anti-aliased edge and for the shadow it
    /// casts past it, and no more. The margin costs nothing next to the notch — a click that
    /// lands in it falls straight through to whatever is under it, see `NotchHostingView` —
    /// but a shadow with no room to fall in is sliced off square at the window's own edge.
    static let restSlack: CGFloat = IslandShadow.reach + 6
    /// Extra room on the sides while a spring is in flight, since springs overshoot.
    /// `IslandMotion.open` carries a bounce of 0.28, which puts the shape about 4 % past its
    /// step at the peak, so the slack scales with the step and this is only the floor.
    static let motionSlack: CGFloat = 14
    static let overshootFraction: CGFloat = 0.06
    /// Longer than the slowest island spring, so the frame only shrinks once the shape is at
    /// rest — the open spring's 0.44 s plus room for it to ring out.
    static let settleDelay: TimeInterval = 0.65

    let geometry: NotchGeometry
    let panelID: String
    /// Identifies the display this panel was built for, in the terms that decide whether it
    /// must be rebuilt: which screen, its size, the notch's height, and — for a display
    /// without a notch — whether it is the primary display. Menu-bar-derived values are left
    /// out on purpose, since a full-screen app changes those; see
    /// `displayKey(number:size:safeAreaTop:isPrimary:)`.
    let displayKey: String
    private let screenNumber: NSNumber?
    private var hosting: NotchHostingView<AnyView>?
    /// A pending hand-back of key status, see `scheduleKeyRelease`.
    private var keyReleaseWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var refitScheduled = false
    private var settleWork: DispatchWorkItem?
    /// Notification observers that keep the island on top, see `assertOnTop`.
    private var orderObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var orderWork: DispatchWorkItem?
    /// The event monitors that follow the pointer, see `watchPointer`.
    private var pointerMonitors: [Any] = []

    /// The panel identifier a screen's island answers to. One place, so everything that
    /// speaks about a display's island — a full-screen check, a hover — spells it the same.
    static func panelID(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "screen-" + (number?.stringValue ?? UUID().uuidString)
    }

    init(screen: NSScreen, geometry: NotchGeometry) {
        self.geometry = geometry
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        self.screenNumber = number
        self.panelID = NotchPanel.panelID(for: screen)
        self.displayKey = NotchPanel.displayKey(for: screen)
        let frame = NotchPanel.frame(for: screen)
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = Self.islandLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The island is always black, so system colours must resolve to their dark variants
        // (the values iOS uses on the Dynamic Island) whatever the desktop appearance is.
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Transparent to the mouse until the pointer reaches the island; see `passesThrough`.
        ignoresMouseEvents = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none

        let root = AnyView(
            IslandRootView(geometry: geometry, panelID: panelID)
                .environmentObject(ActivityCenter.shared)
                .environmentObject(Preferences.shared)
        )
        let view = NotchHostingView(rootView: root)
        view.panelID = panelID
        let geo = geometry
        let pid = panelID
        view.islandLayoutProvider = {
            let center = ActivityCenter.shared
            if center.isSuppressed(panel: pid) { return nil }
            return IslandLayout.make(presentation: center.presentation(for: pid), geometry: geo, center: center)
        }
        // The window decides its own size; SwiftUI must not resize it to the content's ideal.
        // A hosting view used directly as the content view still does (its intrinsic size
        // reaches the window through the content view), so it lives inside a plain view that
        // has no intrinsic size, and keeps the frame it is given.
        view.sizingOptions = []
        // The island is *meant* to sit under the notch and over the menu bar; a safe area
        // would inset it away from the very edge it has to be fused to.
        view.safeAreaRegions = []
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        view.frame = NSRect(origin: .zero, size: frame.size)
        let container = NotchContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        container.addSubview(view)
        contentView = container
        hosting = view
        place(frame)

        // Straight into `scheduleRefit`, with no scheduler in between.
        //
        // A `RunLoop.main` hop costs a whole extra turn of the run loop, and `scheduleRefit`
        // already takes the one hop it needs to read values the change has actually been
        // applied to. With both, the window was still notch-sized when SwiftUI composited the
        // first frames of the growth, so the opening panel was guillotined by a hard rectangle
        // at the notch's own footprint and then the crop snapped away. The `RunLoop.main`
        // scheduler also runs only in the default mode, which meant no refit at all while a
        // menu was tracking.
        Publishers.Merge3(ActivityCenter.shared.objectWillChange, Preferences.shared.objectWillChange,
                          MenuBarClearance.shared.objectWillChange)
            .sink { [weak self] _ in self?.scheduleRefit() }
            .store(in: &cancellables)
        // Out of screen sharing while that is asked for, always or for the length of a call.
        // A call is the detector's, which follows one with the Calls card switched off too,
        // or a call card on the island, which is also how the status menu's demo call counts.
        let prefs = Preferences.shared
        Publishers.CombineLatest4(prefs.$hiddenFromScreenSharing, prefs.$hideFromScreenSharingDuringCalls,
                                  ActivityCenter.shared.$activities.map { $0.contains { $0.kind == .call } },
                                  CallDetector.shared.$call.map { $0 != nil })
            .map { NotchPanel.sharesScreen(hidden: $0.0, duringCalls: $0.1, inCall: $0.2 || $0.3) }
            .removeDuplicates()
            .sink { [weak self] sharing in
                guard Thread.isMainThread else {
                    DispatchQueue.main.async { self?.sharingType = sharing }
                    return
                }
                self?.sharingType = sharing
            }
            .store(in: &cancellables)
        watchForReordering()
        watchPointer()
        refit()
    }

    deinit {
        orderObservers.forEach { $0.center.removeObserver($0.token) }
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    // MARK: - Letting the mouse through

    /// Whether the window should let mouse events through to whatever is under it.
    ///
    /// AppKit sends every mouse event inside a window's frame to that window, drawn on or
    /// not: `NotchHostingView.hitTest` answering nil *drops* the click, it does not hand it
    /// on. And this window is the whole canvas — as tall as the tallest card, as wide as the
    /// island plus its slack. Left receiving, it swallowed every click and scroll in a strip
    /// under the notch three hundred points deep: Safari's tabs and the page under them did
    /// nothing, and a click there could not close the panel either, since the click-outside
    /// monitor only hears the clicks other apps receive. So the window is transparent to the
    /// mouse whenever the pointer is off the island, and solid the moment it arrives.
    ///
    /// `engaged` keeps it solid regardless: a slider being dragged past the island's edge, a
    /// file being dragged over the shelf, the island's own button still held down. An event
    /// stream that began on the island finishes on it.
    static func passesThrough(onIsland: Bool, engaged: Bool, suppressed: Bool) -> Bool {
        if suppressed { return true }
        return !onIsland && !engaged
    }

    /// A ring past the island's own hit rect that still counts as on it, so the pointer's
    /// first moves *off* the island are still delivered to the window: those are the events
    /// that carry the hover exit to the view. A click in the ring hits nothing and is
    /// dropped, which is what the slack around the island always did.
    static let passThroughMargin: CGFloat = 8

    /// Follows the pointer wherever it goes. A window that ignores the mouse hears nothing
    /// from it, so the arrival has to be seen from outside: the global monitor reports the
    /// pointer while other apps have it, the local one while this app does. Each report is
    /// one rectangle test until the pointer is in the window's own frame.
    private func watchPointer() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                            .leftMouseUp, .rightMouseUp, .otherMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            self?.updatePassThrough()
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.updatePassThrough()
            return event
        }) {
            pointerMonitors.append(local)
        }
    }

    /// Whether the pointer was on the island the last time it was seen, so that only a change
    /// is reported. The pointer's every move comes through here, and `setHovering` re-arms its
    /// timer on every call: told on every move, the hover's grace period started over each
    /// time and never ran out while the pointer was moving.
    private var pointerOnIsland = false

    /// `pointerMoved` says a pointer event brought us here. A refit — the island changing
    /// under a pointer that has not moved — updates what the window lets through and reports
    /// a departure, but never an arrival: an island that widened under a pointer resting on
    /// the menu bar beside it is not being pointed at, and reporting it was opened a peek
    /// over the menu item every time a track changed.
    private func updatePassThrough(pointerMoved: Bool = true) {
        let center = ActivityCenter.shared
        let pointer = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons
        // A press whose release went elsewhere — to the drag session a thumbnail started, to
        // another window — would have kept the window solid for good, and the pill at its
        // pressed scale. No button is down, so nothing is pressed.
        if buttons == 0, center.pressedPanel == panelID { center.setPressed(false, panel: panelID) }
        // The body only: a pointer resting on the bubble is not a hover (see
        // `NotchHostingView.outline`), though a click on it is a click.
        let onIsland = islandContains(screenPoint: pointer, includingBubble: false)
        let onIslandOrBubble = onIsland || islandContains(screenPoint: pointer)
        // The ring past the edge counts only on the way out, so the pointer's first moves
        // off the island still reach the window. On the way in it would have been a strip
        // of the menu bar beside the notch, and of the window under it, that swallowed a click.
        let leaving = pointerOnIsland && islandContains(screenPoint: pointer, margin: Self.passThroughMargin)
        // A button held down while the window is solid is a press or a drag that began here.
        let holding = buttons != 0 && !ignoresMouseEvents
        let engaged = holding || center.controlDragging || center.dragPanel == panelID || center.pressedPanel == panelID
        let pass = Self.passesThrough(onIsland: onIslandOrBubble || leaving, engaged: engaged,
                                      suppressed: center.isSuppressed(panel: panelID))
        if ignoresMouseEvents != pass {
            ignoresMouseEvents = pass
            IslandLog.panel.debug("panel \(self.panelID, privacy: .public) \(pass ? "lets the mouse through" : "takes the mouse", privacy: .public)")
        }
        // The view's own hover tracking rides on the events the window receives, and the
        // window stops receiving them the moment it goes transparent — so the arrival and
        // the departure are told to the centre from here as well, once each.
        guard onIsland != pointerOnIsland, pointerMoved || !onIsland else { return }
        pointerOnIsland = onIsland
        center.setHovering(onIsland, panel: panelID)
    }

    /// A click anywhere on a panel that is only under the pointer pins it, see
    /// `ActivityCenter.pinPeek`. The island's own tap and the hosting view's `mouseDown` do
    /// that for a click on the SwiftUI side; a click on one of AppKit's own controls — the
    /// output menu, the Notes editor, the find field, the shelf's drag view — goes straight
    /// to that control and nothing upstream saw it, so picking AirPods from a peek let the
    /// peek close under the menu, and typing into Notes from a peek typed into the app
    /// behind. Every click is seen here first. Pinning ahead of the dispatch also lets
    /// AppKit make the panel key on that same click, which is what the editor needs.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           islandContains(screenPoint: NSEvent.mouseLocation) {
            ActivityCenter.shared.pinPeek(panel: panelID)
        }
        super.sendEvent(event)
    }

    /// Above the menu bar, above other floating panels, above anything an ordinary app can
    /// raise a window to. The island is part of the machine, not a window in the pile.
    static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    /// Whether a screen share — and a screenshot — may see the island: not while it is asked
    /// to be hidden always, nor during a call while it is asked to be hidden then. The panel
    /// can be showing what somebody copied, their notes, or what their notifications said,
    /// and a call is when a screen is shared. Capture built on ScreenCaptureKit on macOS 15
    /// can ignore this; the Privacy pane says so.
    static func sharesScreen(hidden: Bool, duringCalls: Bool, inCall: Bool) -> NSWindow.SharingType {
        hidden || (duringCalls && inCall) ? .none : .readOnly
    }

    /// The island belongs to the screen, not to whatever app is in front: moving windows
    /// about, switching apps or changing Space must never leave it behind another window.
    /// Nothing here activates this app or takes focus — the panel only reclaims its own place
    /// in the order it is already meant to be at the top of.
    private func watchForReordering() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didActivateApplicationNotification,
                                          NSWorkspace.activeSpaceDidChangeNotification,
                                          NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didUnhideApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                // Straight away as well as after the debounce. A Space that slides sideways can
                // carry the island a few points with it, and waiting an eighth of a second to
                // put it back is long enough to watch it happen: the island is meant to be part
                // of the machine, and part of the machine does not slide.
                self.assertOnTop()
                self.scheduleAssertOnTop()
            }
            orderObservers.append((workspace, token))
        }
        let token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            self?.scheduleAssertOnTop()
        }
        orderObservers.append((.default, token))
    }

    /// A run of notifications (activating an app raises several) costs one assertion.
    private func scheduleAssertOnTop() {
        orderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.assertOnTop() }
        orderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.orderAssertDelay, execute: work)
    }

    static let orderAssertDelay: TimeInterval = 0.12

    private func assertOnTop() {
        guard isVisible else { return }
        if level != Self.islandLevel { level = Self.islandLevel }
        // Raising a window puts it back in the order; it does not put it back in its place.
        // A Space transition, a display waking, or a full-screen app arriving can all leave
        // the frame a little off the notch, and nothing else was ever going to correct it.
        placeIfDrifted()
        guard !isKeyWindow else { return }
        orderFrontRegardless()
    }

    /// How far the window may be from where it belongs before it is put back. Half a point,
    /// so a rounding difference is left alone and a slide is not.
    static let driftTolerance: CGFloat = 0.5

    private func placeIfDrifted() {
        guard !refitScheduled else { return }
        let target = restFrame()
        // Never while the island is mid-morph: opening the panel deliberately grows the window
        // past its resting size and shrinks it again when the animation has finished, and this
        // would snap it back into the middle of that. Asked of the window rather than of the
        // pending settle, which is no answer at all: every refit leaves one behind and nothing
        // ever takes it away again, so the one scheduled in `init` stood in front of this
        // correction for the whole life of the panel and it never ran once. A window already
        // the size it rests at is in the middle of nothing — and the settle is aiming at this
        // same rest frame, so the two can never pull the window in different directions.
        //
        // A point of slack either way, as `same(_:_:)` allows: AppKit may round what it is given.
        guard abs(frame.width - target.width) < 1, abs(frame.height - target.height) < 1 else { return }
        // Only where it *is*, not how big it is: the size belongs to whatever the island is
        // showing, and correcting that here would be a second opinion about it.
        guard abs(frame.minX - target.minX) > Self.driftTolerance
                || abs(frame.maxY - target.maxY) > Self.driftTolerance else { return }
        IslandLog.panel.notice("panel \(self.panelID, privacy: .public) drifted off the notch; putting it back")
        place(target)
    }

    /// The island takes key-window status while the panel is pinned open, and while something
    /// on it is being typed into — the Notes scratchpad, or a find. A peek takes nothing:
    /// the pointer is only passing over. Clicks land regardless, thanks to acceptsFirstMouse
    /// on the hosting view.
    ///
    /// It pulls focus from the app in front, and that is the point rather than a cost. The
    /// panel's keys are claimed from every application at once; leaving the keyboard with the
    /// app behind meant clicking the island and carrying on typing put the letters into a find
    /// nobody had asked for instead of into the reply they were writing. Holding the keyboard
    /// is what makes the claim honest, and it is visible — the window behind dims — so it is
    /// obvious where the typing is going.
    override var canBecomeKey: Bool { ActivityCenter.shared.wantsPanelKeyboard }
    override var canBecomeMain: Bool { false }

    /// Key status is what licenses the panel's hot keys, so the centre is told the moment it
    /// changes either way. See `ActivityCenter.panelKeyChanged`.
    override func becomeKey() {
        super.becomeKey()
        ActivityCenter.shared.panelKeyChanged()
    }

    override func resignKey() {
        super.resignKey()
        ActivityCenter.shared.panelKeyChanged()
    }

    /// AppKit keeps ordinary windows clear of the menu bar by pushing them down. This one has
    /// to sit on the screen's top edge, so it keeps the frame it asks for.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Every way the window comes on screen puts it in the island's own space, and every way
    /// it leaves takes it out; see `IslandSpace`. Ordering out and back in is how key status
    /// is handed back (`scheduleKeyRelease`), and a window ordered back in by AppKit is back
    /// in AppKit's spaces alone. Out of the space only once it is off the screen, so it is
    /// never seen dropping into the desktop's layer on its way.
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        if place == .out { IslandSpace.shared.release(self) } else { joinIslandSpace() }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        joinIslandSpace()
    }

    /// The panel, and whatever it has attached: AppKit orders a child back in with its parent,
    /// and a child ordered back in is back in AppKit's spaces alone, as the panel is.
    private func joinIslandSpace() {
        IslandSpace.shared.adopt(self)
        for child in childWindows ?? [] { IslandSpace.shared.adoptChild(child) }
    }

    /// A popover opened from the island — the rail's Display and keyboard-light popovers among
    /// them — is a window of its own, which AppKit attaches to this one as a child. It goes in
    /// the island's space with the panel for as long as it is attached, or the island it came
    /// from could be drawn over it; see `IslandSpace.adoptChild`.
    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        super.addChildWindow(childWin, ordered: place)
        IslandSpace.shared.adoptChild(childWin)
    }

    override func removeChildWindow(_ childWin: NSWindow) {
        super.removeChildWindow(childWin)
        IslandSpace.shared.releaseChild(childWin)
    }

    /// Follows what the panel needs: key status while the panel is pinned or a section that is
    /// typed into is open, handed straight back when that goes.
    private func syncKeyboard() {
        guard ActivityCenter.shared.wantsPanelKeyboard else { return scheduleKeyRelease() }
        keyReleaseWork?.cancel()
        keyReleaseWork = nil
        guard !isKeyWindow, isVisible, ownsKeyboard, !Self.anotherOfOursHasIt else { return }
        makeKey()
    }

    /// Whether another window of this app — Settings, a Quick Look panel — is holding the
    /// keyboard.
    ///
    /// The island wants it whenever the panel is pinned, and this runs on every refit, which
    /// is every published change. Without this the gear on the rail opened Settings and the
    /// island took the keyboard straight back off it: a window with a dead title bar that
    /// would not accept a keystroke, and no way out, because none of the three things that
    /// close the panel fire for our own windows. Space on the shelf did the same to Quick
    /// Look. Wanting the keyboard is not the same as being owed it by our own windows.
    ///
    /// The live window list is read here; the rule it is put to is `PanelKeyboard`.
    private static var anotherOfOursHasIt: Bool {
        let windows = NSApp.windows.map { window in
            (isKey: window.isKeyWindow, isPanel: window is NotchPanel)
        }
        return PanelKeyboard.heldByAnotherOfOurs(windows)
    }

    /// With an island on several screens, the one under the pointer takes the keyboard;
    /// failing that, the main screen's.
    private var ownsKeyboard: Bool {
        // The panel was opened on one island: that island types.
        if let open = ActivityCenter.shared.openPanel { return open == panelID }
        let mouse = NSEvent.mouseLocation
        if screen?.frame.contains(mouse) == true { return true }
        let panels = NSApp.windows.compactMap { $0 as? NotchPanel }.filter { $0.isVisible }
        guard !panels.contains(where: { $0.screen?.frame.contains(mouse) == true }) else { return false }
        return screen == NSScreen.main || panels.first === self
    }

    /// Hands key status back to the app in front. A window that stays on screen has one way to
    /// stop being key: out and straight back in, within the same pass, so nothing is seen to
    /// move. It waits for the closing animation, so the window is never cycled mid-move.
    private func scheduleKeyRelease() {
        guard isKeyWindow, keyReleaseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.keyReleaseWork = nil
            guard self.isKeyWindow, !ActivityCenter.shared.wantsPanelKeyboard else { return }
            self.orderOut(nil)
            self.orderFrontRegardless()
        }
        keyReleaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settled(Self.keyReleaseDelay), execute: work)
    }

    static let keyReleaseDelay: TimeInterval = 0.35

    /// A delay that waits for a closing spring, stretched with the Motion pane's duration.
    /// The delays are set for the shipping springs; turned up to twice the length, the open
    /// spring is still a few points past its target when a fixed delay runs out, and the
    /// window narrowed around it and cut its shadow flat, and the key hand-back cycled the
    /// window in the middle of the close.
    static func settled(_ delay: TimeInterval) -> TimeInterval {
        delay * max(1, IslandMotion.tuning.duration)
    }

    static func displayKey(for screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "?"
        return displayKey(number: number, size: screen.frame.size, safeAreaTop: screen.safeAreaInsets.top,
                          isPrimary: NotchGeometry.isPrimary(screen))
    }

    /// The key itself, from what it is made of, so the rule can be checked without a display.
    ///
    /// On a display without a notch, whether it is the primary one is part of it. Which
    /// displays carry a menu bar follows the primary (every one of them with separate Spaces,
    /// the primary alone without), and a floating island hangs a menu bar's height below the
    /// top of a display that has one and at the very top of one that has not — measured once,
    /// when the panel is built (`NotchGeometry.detect`). Dragging the menu bar to the other
    /// display in the arrangement left every key as it was, so nothing was rebuilt, and the
    /// pill stayed hanging under a menu bar that had gone, or over one that had arrived. A
    /// notched island is as tall as the housing wherever the menu bar is, so its key leaves
    /// the primary out, and plugging in a monitor that takes the menu bar does not rebuild it.
    static func displayKey(number: String, size: CGSize, safeAreaTop: CGFloat, isPrimary: Bool) -> String {
        let key = "\(number)|\(Int(size.width))x\(Int(size.height))|\(Int(safeAreaTop))"
        guard safeAreaTop == 0 else { return key }
        return key + (isPrimary ? "|primary" : "|secondary")
    }

    /// Whether a point in screen coordinates lies on this panel's island (not merely inside
    /// the window, whose slack around the island is click-through). Geometry only; it never
    /// runs a view hit test, so it costs nothing and touches no view state.
    func islandContains(screenPoint: NSPoint, margin: CGFloat = 0, includingBubble: Bool = true) -> Bool {
        guard frame.contains(screenPoint), let hosting else { return false }
        return hosting.islandContains(windowPoint: convertPoint(fromScreen: screenPoint), margin: margin,
                                      includingBubble: includingBubble)
    }

    /// The resting frame for a screen before any state exists: the bare notch plus slack.
    static func frame(for screen: NSScreen) -> NSRect {
        let geometry = NotchGeometry.detect(on: screen)
        let half = geometry.notchWidth / 2
        return frame(leading: half, trailing: half, height: geometry.notchHeight, slack: restSlack, in: screen.frame)
    }

    // MARK: - Frame tracking

    /// The screen this panel belongs to, looked up fresh because frames move when displays are
    /// rearranged; the geometry captured at creation is the fallback.
    private var screenFrame: CGRect {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenNumber }?.frame
            ?? geometry.screenFrame
    }

    /// A top-anchored rect reaching `leading` left and `trailing` right of the notch centre,
    /// plus slack, kept inside the screen. Asymmetric on purpose: the bubble hangs off the
    /// right, and the window must not cover anything on the left that has nothing under it.
    /// The height is the canvas, whatever `height` is asked for — see the note on the class.
    private static func frame(leading: CGFloat, trailing: CGFloat, height: CGFloat, slack: CGFloat, in screen: CGRect) -> NSRect {
        let minX = max(screen.minX, (screen.midX - leading - slack).rounded())
        let maxX = min(screen.maxX, (screen.midX + trailing + slack).rounded())
        let h = min(canvasHeight, screen.height)
        return NSRect(x: minX, y: screen.maxY - h, width: max(1, maxX - minX), height: h)
    }

    /// The island's reach from the notch centre right now, before slack.
    private func extents() -> (leading: CGFloat, trailing: CGFloat, height: CGFloat) {
        let center = ActivityCenter.shared
        if center.isSuppressed(panel: panelID) {
            return (geometry.notchWidth / 2, geometry.notchWidth / 2, geometry.notchHeight)
        }
        let layout = IslandLayout.make(presentation: center.presentation(for: panelID), geometry: geometry, center: center)
        return (layout.hitLeading, layout.hitTrailing, layout.hitHeight)
    }

    private func restFrame() -> NSRect {
        let e = extents()
        return Self.frame(leading: e.leading, trailing: e.trailing, height: e.height, slack: Self.restSlack, in: screenFrame)
    }

    /// Moves the window and keeps the hosting view centred on the notch. The view is as wide
    /// as it must be to reach both window edges from the notch centre, so it overhangs the
    /// narrower side; the overhang lies outside the window and is neither drawn nor clickable,
    /// which is what lets the window be asymmetric while SwiftUI keeps centring on the notch.
    private func place(_ rect: NSRect) {
        // A rect that lost touch with the screen (a display going away mid-change) must never
        // reach AppKit: an infinite or NaN frame is an exception, not a warning.
        guard !rect.isNull, rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite,
              rect.width >= 1, rect.height >= 1 else {
            IslandLog.panel.error("panel \(self.panelID, privacy: .public) refused frame \(NSStringFromRect(rect), privacy: .public)")
            return
        }
        IslandLog.panel.notice("panel \(self.panelID, privacy: .public) placing \(NSStringFromRect(rect), privacy: .public) from \(NSStringFromRect(self.frame), privacy: .public)")
        // The window is drawn on the next turn of the run loop like any other change; asking
        // for a synchronous display here would lay the SwiftUI tree out from inside whatever
        // called us, in the middle of its own update.
        setFrame(rect, display: false)
        guard let hosting else { return }
        let notchX = screenFrame.midX - rect.minX
        let half = max(notchX, rect.width - notchX)
        let hostingFrame = NSRect(x: (notchX - half).rounded(), y: 0, width: (half * 2).rounded(), height: rect.height)
        if hosting.frame != hostingFrame { hosting.frame = hostingFrame }
        IslandLog.panel.notice("panel \(self.panelID, privacy: .public) frame \(NSStringFromRect(self.frame), privacy: .public) hosting \(NSStringFromRect(hosting.frame), privacy: .public)")
    }

    /// Frames that differ by less than a point are the same frame: AppKit may round what it
    /// is given, and a settle that keeps re-placing an equal rect would lay the view out on
    /// every beat for nothing.
    private static func same(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// Several published changes land in one runloop turn; one refit covers them all, after the
    /// changes have been applied (objectWillChange fires before them).
    private func scheduleRefit() {
        // Nothing in AppKit may be touched from anywhere but the main thread, and this is now
        // called straight from whatever wrote the value — including, one day, a service that
        // publishes from a background queue.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scheduleRefit() }
            return
        }
        guard !refitScheduled else { return }
        refitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refitScheduled = false
            self?.refit()
        }
    }

    /// Bring the frame in line with the island. Growth is immediate, with room for the spring;
    /// shrinking waits until the closing animation has finished.
    func refit() {
        updatePassThrough(pointerMoved: false)
        syncKeyboard()

        settleWork?.cancel()
        let target = restFrame()
        let current = frame
        // Width and top edge only. The height is the canvas and is never touched here: a window
        // that changes height in the turn that opens the panel is the whole reason the island
        // used to grow from a hundred points below the notch.
        let needsRoom = target.minX < current.minX - 0.5 || target.maxX > current.maxX + 0.5
            || abs(target.maxY - current.maxY) > 0.5 || abs(target.height - current.height) > 0.5
        if needsRoom {
            let union = current.union(target)
            let slackX = max(Self.motionSlack, abs(target.width - current.width) * Self.overshootFraction)
            let grown = NSRect(x: union.minX - slackX, y: target.minY,
                               width: union.width + slackX * 2, height: target.height)
            place(grown.intersection(screenFrame))
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A drag in progress must keep its drop target under the pointer; settle later.
            if ActivityCenter.shared.dragPanel == self.panelID {
                self.refit()
                return
            }
            let rest = self.restFrame()
            if !Self.same(self.frame, rest) { self.place(rest) }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settled(Self.settleDelay), execute: work)
    }
}

/// Who among this app's own windows is holding the keyboard.
///
/// The decision on its own, away from `NSApp`, so it can be asked with a list of windows
/// rather than with an application running. `NotchPanel.anotherOfOursHasIt` reads the live
/// list and hands it in; nothing here decides anything that call does not.
enum PanelKeyboard {
    /// Whether one of our windows that is not an island panel — Settings, a Quick Look panel —
    /// is the key window, in which case the island leaves the keyboard where it is.
    static func heldByAnotherOfOurs(_ windows: [(isKey: Bool, isPanel: Bool)]) -> Bool {
        windows.contains { $0.isKey && !$0.isPanel }
    }
}
