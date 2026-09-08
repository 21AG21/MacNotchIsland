import AppKit
import ApplicationServices
import Combine

/// How much of the menu bar is free on either side of the notch.
///
/// The compact island widens sideways into the menu bar, where the frontmost app's menus end
/// on the left and the status items begin on the right. Covering either hides text, so the
/// island only takes room that is actually free. Status items are read from the window list
/// (each is a window of its own, no permission needed); the app's menu titles are read through
/// Accessibility when the app is trusted for it, and assumed clear otherwise, which holds for
/// all but the widest menus on a 15-inch display.
final class MenuBarClearance: ObservableObject {
    static let shared = MenuBarClearance()

    struct Limits: Equatable {
        /// Points free to the left and right of the notch; nil means unknown, treated as unlimited.
        var leading: CGFloat? = nil
        var trailing: CGFloat? = nil
        static let unlimited = Limits()
    }

    @Published private(set) var limits = Limits.unlimited

    /// Status item windows sit at this level (`NSWindow.Level.statusBar`).
    static let statusItemLayer = 25

    /// Each token with the centre it came from; workspace notifications live on the
    /// workspace's own centre and must be removed there.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    /// A slow window-list walk must not overwrite the result of a later one.
    private var generation = 0

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        // Menus belong to the frontmost app, so they change whenever it does; a moment later,
        // once the new menu bar has been laid out.
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(after: 0.35)
        }))
        observers.append((.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(after: 0.6)
        }))
        // Status items come and go without any notification; a slow poll catches them.
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 8
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func stop() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        if limits != .unlimited { limits = .unlimited }
    }

    func refresh(after delay: TimeInterval = 0) {
        guard timer != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshNow() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            if limits != .unlimited { limits = .unlimited }
            return
        }
        let geometry = NotchGeometry.detect(on: screen)
        let frame = screen.frame
        let notch = CGRect(x: frame.midX - geometry.notchWidth / 2, y: 0, width: geometry.notchWidth, height: geometry.notchHeight)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let app = NSWorkspace.shared.frontmostApplication
        generation += 1
        let ticket = generation
        // The window list walk and the Accessibility round trip both belong off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let band = Self.menuBarBand(screenFrame: frame, primaryHeight: primaryHeight, notchHeight: geometry.notchHeight)
            let trailing = Self.statusItemClearance(windows: windows, menuBar: band, notchMaxX: notch.maxX)
            let leading = Self.menuClearance(app: app, notchMinX: notch.minX)
            let measured = Limits(leading: leading, trailing: trailing)
            DispatchQueue.main.async {
                guard let self, self.timer != nil, ticket == self.generation else { return }
                let next = Self.settled(measured, from: self.limits)
                guard self.limits != next else { return }
                self.limits = next
            }
        }
    }

    /// The menu bar's band on a screen, in the window list's coordinate space: origin at the
    /// top-left of the primary display, y growing downward.
    static func menuBarBand(screenFrame: CGRect, primaryHeight: CGFloat, notchHeight: CGFloat) -> CGRect {
        CGRect(x: screenFrame.minX, y: primaryHeight - screenFrame.maxY, width: screenFrame.width, height: notchHeight)
    }

    /// A measurement worth acting on.
    ///
    /// Menu bars twitch: a title's frame comes back a point or two different depending on when
    /// it is read, and a status item that redraws itself moves the edge by a hair. The island
    /// is anchored to the notch and people notice it moving, so a new measurement is only
    /// taken up when it is far enough from the last one to change what actually fits.
    static func settled(_ new: Limits, from old: Limits) -> Limits {
        Limits(leading: settled(new.leading, from: old.leading),
               trailing: settled(new.trailing, from: old.trailing))
    }

    private static func settled(_ new: CGFloat?, from old: CGFloat?) -> CGFloat? {
        guard let new, let old else { return new }
        return abs(new - old) < noise ? old : new
    }

    /// How far a measurement must move before the island does.
    static let noise: CGFloat = 8

    // MARK: - Pure measurements

    /// Room between the notch's right edge and the nearest status item, from window-list
    /// entries (CoreGraphics top-left coordinates, `menuBar` being the menu bar's band on the
    /// notched screen). Nil when no status item is on that side of the menu bar.
    static func statusItemClearance(windows: [[String: Any]], menuBar: CGRect, notchMaxX: CGFloat) -> CGFloat? {
        var nearest: CGFloat?
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == statusItemLayer,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width > 0,
                  bounds.minY >= menuBar.minY - 1, bounds.minY < menuBar.maxY,
                  bounds.maxX > notchMaxX, bounds.minX < menuBar.maxX else { continue }
            // A window that starts left of the notch and reaches past it leaves no room at all.
            nearest = min(nearest ?? .infinity, max(bounds.minX, notchMaxX))
        }
        return nearest.map { max(0, $0 - notchMaxX) }
    }

    /// Room between the frontmost app's last menu title and the notch's left edge. Needs the
    /// Accessibility permission; nil without it, or when the menu bar cannot be read.
    static func menuClearance(app: NSRunningApplication?, notchMinX: CGFloat) -> CGFloat? {
        guard let app, AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBarValue, CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return nil }
        let menuBar = menuBarValue as! AXUIElement   // type checked just above
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let items = childrenValue as? [AXUIElement], !items.isEmpty else { return nil }
        var rightEdge: CGFloat = 0
        for item in items {
            guard let frame = frame(of: item) else { continue }
            rightEdge = max(rightEdge, frame.maxX)
        }
        return max(0, notchMinX - rightEdge)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),   // type checked just above
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// The width a side of the compact island may use: its full width when that fits, the
    /// glyph-only width when only that fits, nothing otherwise. A few points of margin keep
    /// the island from touching the next menu bar item.
    static func fitted(_ full: CGFloat, minimal: CGFloat, free: CGFloat?) -> CGFloat {
        guard let free else { return full }
        let usable = free - margin
        if usable >= full { return full }
        if minimal > 0, usable >= minimal { return minimal }
        return 0
    }

    static let margin: CGFloat = 4
}
