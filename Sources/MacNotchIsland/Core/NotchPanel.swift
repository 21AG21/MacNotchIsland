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
    /// Room around the island at rest: enough for its anti-aliased edge, too little to cover
    /// anything next to the notch.
    static let restSlack: CGFloat = 4
    /// Extra room on the sides and below while a spring is in flight, since springs overshoot.
    /// The open spring (damping 0.72) overshoots by about 4 % of the step, so the slack scales
    /// with the step and this is only the floor.
    static let motionSlack: CGFloat = 14
    static let overshootFraction: CGFloat = 0.06
    /// Longer than the slowest island spring, so the frame only shrinks once the shape is at rest.
    static let settleDelay: TimeInterval = 0.65

    let geometry: NotchGeometry
    let panelID: String
    /// Identifies the display this panel was built for, in the terms that decide whether it
    /// must be rebuilt: which screen, its size, and the notch's height. Menu-bar-derived
    /// values are left out on purpose, since a full-screen app changes those.
    let displayKey: String
    private let screenNumber: NSNumber?
    private var hosting: NotchHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var refitScheduled = false
    private var settleWork: DispatchWorkItem?

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
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
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
        view.sizingOptions = []
        view.frame = NSRect(origin: .zero, size: frame.size)
        contentView = view
        hosting = view
        place(frame)

        Publishers.Merge3(ActivityCenter.shared.objectWillChange, Preferences.shared.objectWillChange,
                          MenuBarClearance.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefit() }
            .store(in: &cancellables)
        refit()
    }

    /// The island has no text input, so it never takes key-window status away from the app the
    /// user is working in (clicks still land thanks to acceptsFirstMouse on the hosting view).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func displayKey(for screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "?"
        return "\(number)|\(Int(screen.frame.width))x\(Int(screen.frame.height))|\(Int(screen.safeAreaInsets.top))"
    }

    /// Whether a point in screen coordinates lies on this panel's island (not merely inside
    /// the window, whose slack around the island is click-through).
    func islandContains(screenPoint: NSPoint) -> Bool {
        guard frame.contains(screenPoint), let hosting else { return false }
        return hosting.hitTest(convertPoint(fromScreen: screenPoint)) != nil
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
        setFrame(rect, display: true)
        guard let hosting else { return }
        let notchX = screenFrame.midX - rect.minX
        let half = max(notchX, rect.width - notchX)
        hosting.frame = NSRect(x: (notchX - half).rounded(), y: 0, width: (half * 2).rounded(), height: rect.height)
        IslandLog.panel.notice("panel \(self.panelID, privacy: .public) frame \(NSStringFromRect(rect), privacy: .public) hosting \(NSStringFromRect(hosting.frame), privacy: .public)")
    }

    /// Several published changes land in one runloop turn; one refit covers them all, after the
    /// changes have been applied (objectWillChange fires before them).
    private func scheduleRefit() {
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
            if self.frame != rest { self.place(rest) }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }
}
