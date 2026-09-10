import AppKit
import Combine
import SwiftUI

/// A transparent panel that floats above the menu bar and full-screen apps, positioned over the
/// notch of its screen.
///
/// The window is never larger than the island it shows. Its frame follows the island's footprint:
/// it grows the instant something opens (so the spring has room to overshoot) and shrinks back a
/// moment after something closes. At rest it hugs the notch, so the menu bar and the windows
/// beside it stay clickable; there is no invisible canvas to bump into.
final class NotchPanel: NSPanel {
    static let canvasHeight: CGFloat = 340
    /// Room around the island at rest: enough for its anti-aliased edge and for the shadow it
    /// casts past it, and no more. The margin costs nothing next to the notch — a click that
    /// lands in it falls straight through to whatever is under it, see `NotchHostingView` —
    /// but a shadow with no room to fall in is sliced off square at the window's own edge.
    static let restSlack: CGFloat = IslandShadow.reach + 6
    /// Extra room on the sides and below while a spring is in flight, since springs overshoot.
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
    /// must be rebuilt: which screen, its size, and the notch's height. Menu-bar-derived
    /// values are left out on purpose, since a full-screen app changes those.
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

    init(screen: NSScreen, geometry: NotchGeometry) {
        self.geometry = geometry
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        self.screenNumber = number
        self.panelID = "screen-" + (number?.stringValue ?? UUID().uuidString)
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
        ignoresMouseEvents = false
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
        view.hitExtentsProvider = {
            if ActivityCenter.shared.isSuppressed { return (0, 0, 0) }
            let layout = IslandLayout.make(presentation: ActivityCenter.shared.presentation(for: pid), geometry: geo)
            return (layout.hitLeading, layout.hitTrailing, layout.hitHeight)
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
        watchForReordering()
        refit()
    }

    deinit {
        orderObservers.forEach { $0.center.removeObserver($0.token) }
    }

    /// Above the menu bar, above other floating panels, above anything an ordinary app can
    /// raise a window to. The island is part of the machine, not a window in the pile.
    static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

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
        // Never while the island is mid-morph: opening the panel deliberately grows the window
        // past its resting size and shrinks it again when the animation has finished, and this
        // would snap it back into the middle of that.
        guard settleWork == nil, !refitScheduled else { return }
        let target = restFrame()
        // Only where it *is*, not how big it is: the size belongs to whatever the island is
        // showing, and correcting that here would be a second opinion about it.
        guard abs(frame.minX - target.minX) > Self.driftTolerance
                || abs(frame.maxY - target.maxY) > Self.driftTolerance else { return }
        IslandLog.panel.notice("panel \(self.panelID, privacy: .public) drifted off the notch; putting it back")
        place(target)
    }

    /// The island takes key-window status only while something is being typed into — the Notes
    /// scratchpad, or a find open on one of the sections that are lists — so it never pulls
    /// focus from the app the user is working in. Clicks land regardless, thanks to
    /// acceptsFirstMouse on the hosting view.
    override var canBecomeKey: Bool { ActivityCenter.shared.wantsKeyboard }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps ordinary windows clear of the menu bar by pushing them down. This one has
    /// to sit on the screen's top edge, so it keeps the frame it asks for.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Follows what the panel needs: key status while a section that is typed into is open,
    /// handed straight back when that section goes.
    private func syncKeyboard() {
        guard ActivityCenter.shared.wantsKeyboard else { return scheduleKeyRelease() }
        keyReleaseWork?.cancel()
        keyReleaseWork = nil
        guard !isKeyWindow, isVisible, ownsKeyboard else { return }
        makeKey()
    }

    /// With an island on several screens, the one under the pointer takes the keyboard;
    /// failing that, the main screen's.
    private var ownsKeyboard: Bool {
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
            guard self.isKeyWindow, !ActivityCenter.shared.wantsKeyboard else { return }
            self.orderOut(nil)
            self.orderFrontRegardless()
        }
        keyReleaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyReleaseDelay, execute: work)
    }

    static let keyReleaseDelay: TimeInterval = 0.35

    static func displayKey(for screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "?"
        return "\(number)|\(Int(screen.frame.width))x\(Int(screen.frame.height))|\(Int(screen.safeAreaInsets.top))"
    }

    /// Whether a point in screen coordinates lies on this panel's island (not merely inside
    /// the window, whose slack around the island is click-through). Geometry only; it never
    /// runs a view hit test, so it costs nothing and touches no view state.
    func islandContains(screenPoint: NSPoint) -> Bool {
        guard frame.contains(screenPoint), let hosting else { return false }
        return hosting.islandContains(windowPoint: convertPoint(fromScreen: screenPoint))
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
    private static func frame(leading: CGFloat, trailing: CGFloat, height: CGFloat, slack: CGFloat, in screen: CGRect) -> NSRect {
        let minX = max(screen.minX, (screen.midX - leading - slack).rounded())
        let maxX = min(screen.maxX, (screen.midX + trailing + slack).rounded())
        let h = min(canvasHeight, screen.height, height + slack)
        return NSRect(x: minX, y: screen.maxY - h, width: max(1, maxX - minX), height: h)
    }

    /// The island's reach from the notch centre right now, before slack.
    private func extents() -> (leading: CGFloat, trailing: CGFloat, height: CGFloat) {
        let center = ActivityCenter.shared
        if center.isSuppressed {
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
        let suppressed = ActivityCenter.shared.isSuppressed
        if ignoresMouseEvents != suppressed { ignoresMouseEvents = suppressed }
        syncKeyboard()

        settleWork?.cancel()
        let target = restFrame()
        let current = frame
        let needsRoom = target.minX < current.minX - 0.5 || target.maxX > current.maxX + 0.5
            || target.height > current.height + 0.5 || abs(target.maxY - current.maxY) > 0.5
        if needsRoom {
            // Both rects hang from the top edge, so growing the union sideways and downward
            // keeps the top where it is.
            let union = current.union(target)
            let slackX = max(Self.motionSlack, abs(target.width - current.width) * Self.overshootFraction)
            let slackY = max(Self.motionSlack, abs(target.height - current.height) * Self.overshootFraction)
            let grown = NSRect(x: union.minX - slackX, y: union.minY - slackY,
                               width: union.width + slackX * 2, height: union.height + slackY)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }
}
