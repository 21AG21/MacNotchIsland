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
    static let canvasWidth: CGFloat = 760
    static let canvasHeight: CGFloat = 340
    /// Room around the island at rest: enough for its anti-aliased edge, too little to cover
    /// anything next to the notch.
    static let restSlack: CGFloat = 4
    /// Extra room on the sides and below while a spring is in flight, since springs overshoot.
    static let motionSlack: CGFloat = 14
    /// Longer than the slowest island spring, so the frame only shrinks once the shape is at rest.
    static let settleDelay: TimeInterval = 0.65

    let geometry: NotchGeometry
    let panelID: String
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
        view.hitSizeProvider = {
            if ActivityCenter.shared.isSuppressed { return .zero }
            return IslandLayout.make(presentation: ActivityCenter.shared.presentation(for: pid), geometry: geo).hitSize
        }
        // The window decides its own size; SwiftUI must not resize it to the content's ideal.
        view.sizingOptions = []
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
        hosting = view
        setFrame(frame, display: true)

        Publishers.Merge(ActivityCenter.shared.objectWillChange, Preferences.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefit() }
            .store(in: &cancellables)
        refit()
    }

    /// The island has no text input, so it never takes key-window status away from the app the
    /// user is working in (clicks still land thanks to acceptsFirstMouse on the hosting view).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The resting frame for a screen before any state exists: the bare notch plus slack.
    static func frame(for screen: NSScreen) -> NSRect {
        let geometry = NotchGeometry.detect(on: screen)
        let size = CGSize(width: geometry.notchWidth + restSlack * 2, height: geometry.notchHeight + restSlack)
        return fit(size, in: screen.frame)
    }

    // MARK: - Frame tracking

    /// The screen this panel belongs to, looked up fresh because frames move when displays are
    /// rearranged; the geometry captured at creation is the fallback.
    private var screenFrame: CGRect {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenNumber }?.frame
            ?? geometry.screenFrame
    }

    /// Top-anchored, centred on the notch, never wider than the canvas or the screen.
    private static func fit(_ size: CGSize, in screen: CGRect) -> NSRect {
        let w = min(canvasWidth, screen.width, size.width)
        let h = min(canvasHeight, screen.height, size.height)
        return NSRect(x: (screen.midX - w / 2).rounded(), y: screen.maxY - h, width: w, height: h)
    }

    /// What the island needs right now, before slack.
    private func islandSize() -> CGSize {
        let center = ActivityCenter.shared
        if center.isSuppressed { return geometry.notchSize }
        return IslandLayout.make(presentation: center.presentation(for: panelID), geometry: geometry, center: center).hitSize
    }

    private func restFrame() -> NSRect {
        let size = islandSize()
        return Self.fit(CGSize(width: size.width + Self.restSlack * 2, height: size.height + Self.restSlack), in: screenFrame)
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
        let needsRoom = target.width > current.width + 0.5 || target.height > current.height + 0.5
            || abs(target.midX - current.midX) > 0.5 || abs(target.maxY - current.maxY) > 0.5
        if needsRoom {
            var union = current.union(target)
            union.origin.x -= Self.motionSlack
            union.size.width += Self.motionSlack * 2
            union.origin.y -= Self.motionSlack
            union.size.height += Self.motionSlack
            setFrame(Self.fit(union.size, in: screenFrame), display: true)
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let rest = self.restFrame()
            if self.frame != rest { self.setFrame(rest, display: true) }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }
}
