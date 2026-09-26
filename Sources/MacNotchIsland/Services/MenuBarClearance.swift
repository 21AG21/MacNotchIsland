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
    /// The measurement asked for and not yet started, and when it is due, on the clock that only
    /// counts forwards (`LocalWrite.now`). Main thread.
    private var pending: DispatchWorkItem?
    private var pendingDue: TimeInterval?
    /// When the last measurement set off, on the same clock. Main thread.
    private var lastRefreshAt = LocalWrite.never
    /// One measurement out at a time, and one more after it at most when it is asked for while
    /// the first is out. Main thread. With one at a time on one serial queue a slow walk can
    /// never land over a later one, which is what a count of walks used to guard against.
    private var pass = RadioPass()
    /// Where the window list and the front app's menu bar are read: one queue, one walk at a
    /// time. Each ask used to start a block of its own on a global queue, as many at once as
    /// were asked for, each able to wait on an app that has stopped answering.
    private let queue = DispatchQueue(label: "com.macnotchisland.menu-bar-clearance", qos: .utility)

    /// The least time between the starts of two measurements.
    ///
    /// Every alert asks for one, since the island is about to widen into the menu bar, and a
    /// scroll of the volume or the brightness is an alert a turn: up to thirty walks of the
    /// window list and of the front app's menu bar a second, each item of it a round trip
    /// through Accessibility. A second is quicker than anybody changes what the menu bar holds,
    /// and the widening it measures for is already on screen.
    static let hold: TimeInterval = 1

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
        pendingDue = nil
        // Started again, the first ask is measured at once, as it is at launch.
        lastRefreshAt = LocalWrite.never
        if limits != .unlimited { limits = .unlimited }
    }

    /// Measures the menu bar `delay` from now, or at the end of the hold on the last measurement
    /// (`hold`), whichever is later. Main thread.
    ///
    /// An ask inside the hold is answered by one measurement at its end, which every ask made
    /// meanwhile shares, rather than one each; a measurement already waiting for that moment or
    /// a later one answers it outright. The first ask after a quiet second is measured at once.
    /// An ask with a delay of its own — an app just switched to, whose menu bar is still being
    /// laid out — still waits that long: an alert straight after it used to cancel it and
    /// measure the menu bar before the new app's menus were on it.
    func refresh(after delay: TimeInterval = 0) {
        guard timer != nil else { return }
        let now = LocalWrite.now()
        let due = Self.refreshDue(asked: now + delay, lastAt: lastRefreshAt)
        guard !Self.answered(due: due, byPendingAt: pending == nil ? nil : pendingDue) else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.pendingDue = nil
            self.refreshNow()
        }
        pending = work
        pendingDue = due
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - now), execute: work)
    }

    /// When an ask made for `asked` is measured, the last measurement having started at `lastAt`:
    /// when it was asked for, or at the end of the hold on the last one if that is later. Pure.
    static func refreshDue(asked: TimeInterval, lastAt: TimeInterval,
                           hold: TimeInterval = MenuBarClearance.hold) -> TimeInterval {
        max(asked, lastAt + hold)
    }

    /// Whether a measurement already waiting, due at `pendingDue`, answers an ask due at `due`:
    /// it does when it starts no sooner, since it then measures the menu bar as the ask would
    /// have. Nil, nothing waiting, answers nothing. Pure.
    static func answered(due: TimeInterval, byPendingAt pendingDue: TimeInterval?) -> Bool {
        guard let pendingDue else { return false }
        return pendingDue >= due
    }

    private func refreshNow() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            if limits != .unlimited { limits = .unlimited }
            return
        }
        // One out already: this ask is taken up when it lands, at the hold's pace.
        guard pass.start() else { return }
        lastRefreshAt = LocalWrite.now()
        let geometry = NotchGeometry.detect(on: screen)
        let frame = screen.frame
        let notch = CGRect(x: frame.midX - geometry.notchWidth / 2, y: 0, width: geometry.notchWidth, height: geometry.notchHeight)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let app = NSWorkspace.shared.frontmostApplication
        // The window list walk and the Accessibility round trip both belong off the main thread.
        queue.async { [weak self] in
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let band = Self.menuBarBand(screenFrame: frame, primaryHeight: primaryHeight, notchHeight: geometry.notchHeight)
            let trailing = Self.statusItemClearance(windows: windows, menuBar: band, notchMaxX: notch.maxX)
            let leading = Self.menuClearance(app: app, menuBar: band, notchMinX: notch.minX)
            let measured = Limits(leading: leading, trailing: trailing)
            DispatchQueue.main.async {
                guard let self else { return }
                let again = self.pass.finish()
                if self.timer != nil {
                    let next = Self.settled(measured, from: self.limits)
                    if self.limits != next { self.limits = next }
                }
                // Asked for while this one was out: once more, when the hold allows.
                if again { self.refresh() }
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

    /// Room between the frontmost app's last menu title and the notch's left edge, `menuBar`
    /// being the menu bar's band on the notched screen. Needs the Accessibility permission;
    /// nil without it, or when the menu bar cannot be read.
    ///
    /// Asked on every switch of app, of the app just switched to — which is the app most
    /// likely to be the one that has stopped answering, somebody having clicked on it to see
    /// why. Given half a second rather than the default six — the app, its menu bar and each
    /// item, since none inherits another's (`WindowsMonitor.bounded`): a thread held that long
    /// on each switch piles up behind itself, and a measurement that late is of a menu bar
    /// nobody is looking at any more.
    static func menuClearance(app: NSRunningApplication?, menuBar band: CGRect, notchMinX: CGFloat) -> CGFloat? {
        guard let app, AXIsProcessTrusted() else { return nil }
        let application = WindowsMonitor.bounded(AXUIElementCreateApplication(app.processIdentifier))
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBarValue, CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return nil }
        let menuBar = WindowsMonitor.bounded(menuBarValue as! AXUIElement)   // type checked just above
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let items = childrenValue as? [AXUIElement], !items.isEmpty else { return nil }
        return menuClearance(itemFrames: items.compactMap { frame(of: WindowsMonitor.bounded($0)) },
                             menuBar: band, notchMinX: notchMinX)
    }

    /// The same, from the menu titles' frames (Accessibility's top-left coordinates, which are
    /// the window list's).
    ///
    /// Only titles on the notched screen's menu bar count, a title being on it when its middle
    /// is — a display beside this one starts where this one ends, and its first title can
    /// touch the edge of this band. The app's menus are drawn on the menu bar of the display
    /// that has the keyboard, and Accessibility reports them there: with that display the
    /// external one, every title was taken to be beside the notch anyway, and the room came
    /// out as nothing (a display to the right) or as the width of the desk (one to the left).
    /// Titles that are somewhere else say nothing about this menu bar, so the answer is
    /// unknown, as it is without the permission.
    static func menuClearance(itemFrames: [CGRect], menuBar: CGRect, notchMinX: CGFloat) -> CGFloat? {
        let here = itemFrames.filter { $0.width > 0 && menuBar.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        guard let rightEdge = here.map(\.maxX).max() else { return nil }
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
