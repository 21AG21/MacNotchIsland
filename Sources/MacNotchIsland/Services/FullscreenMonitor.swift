import AppKit
import ApplicationServices
import Combine

/// Hides an island while the frontmost app has a window covering that island's whole display
/// (full-screen video, games, presentations). Polls the window list every 2 s, scaled by
/// EnergyPolicy, and only while the preference is on.
///
/// Per display. A film full screen on the external display hides that display's island and
/// leaves the MacBook's alone; one flag for every island hid the lot, and closed whatever
/// panel was open on a display the film was nowhere near.
final class FullscreenMonitor {
    private var timer: Timer?
    private var energyCancellable: AnyCancellable?
    private var spaceObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        scheduleTimer()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
        // Entering full screen creates a Space; check at once rather than on the next poll,
        // so the island never lingers over a freshly full-screen app.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        energyCancellable = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        if !ActivityCenter.shared.fullscreenPanels.isEmpty { ActivityCenter.shared.fullscreenPanels = [] }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = 2.0 * EnergyPolicy.shared.pollingMultiplier
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // AppKit lookups on main; the window-list walk (every on-screen window) off it.
        let app = NSWorkspace.shared.frontmostApplication
        let screens = Self.screens()
        let trusted = AXIsProcessTrusted()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let covered = Self.coveredPanels(app: app, screens: screens, axTrusted: trusted)
            DispatchQueue.main.async { self?.apply(covered) }
        }
    }

    private func apply(_ covered: Set<String>) {
        guard timer != nil else { return }
        let center = ActivityCenter.shared
        guard center.fullscreenPanels != covered else { return }
        let newlyCovered = covered.subtracting(center.fullscreenPanels)
        center.fullscreenPanels = covered
        if Self.forgetsInteraction(newlyCovered: newlyCovered, hover: center.hoverPanel, drag: center.dragPanel,
                                   isOpen: center.isOpen, openPanel: center.openPanel) {
            center.clearInteraction()
        }
    }

    /// Whether a display going full screen takes the pointer's work with it: it does when
    /// the pointer, a drag or the open panel was on that display, or the panel is open on
    /// every display at once. An island on a display the film is nowhere near keeps its
    /// panel.
    static func forgetsInteraction(newlyCovered: Set<String>, hover: String?, drag: String?,
                                   isOpen: Bool, openPanel: String?) -> Bool {
        guard !newlyCovered.isEmpty else { return false }
        if let hover, newlyCovered.contains(hover) { return true }
        if let drag, newlyCovered.contains(drag) { return true }
        guard isOpen else { return false }
        guard let openPanel else { return true }
        return newlyCovered.contains(openPanel)
    }

    /// One display as the window list sees it: the island it carries, its frame in
    /// CGWindowList's top-left coordinate space, and how much of its top edge a full-screen
    /// window leaves clear — the camera housing, on a display that has one.
    struct Screen: Equatable {
        var panelID: String
        var rect: CGRect
        var top: CGFloat
    }

    static func screens() -> [Screen] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { screen in
            Screen(panelID: NotchPanel.panelID(for: screen),
                   rect: CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                                width: screen.frame.width, height: screen.frame.height),
                   top: screen.safeAreaInsets.top)
        }
    }

    /// The islands whose display the frontmost app (not us, not Finder) covers with a window.
    ///
    /// A full-screen window fills the display's frame exactly — except on a display with a
    /// camera housing, where it stops below the housing and so is the housing's height
    /// short; `covers` explains why that shorter match needs the app's own word for it,
    /// which is what the Accessibility check supplies when the user has granted it.
    static func coveredPanels(app: NSRunningApplication?, screens: [Screen], axTrusted: Bool) -> Set<String> {
        guard let app,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleIdentifier != "com.apple.finder" else { return [] }
        let pid = app.processIdentifier
        var frames: [CGRect] = []
        if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for window in windows {
                guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      (window[kCGWindowLayer as String] as? Int) == 0,
                      let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
                frames.append(bounds)
            }
        }
        let reported = axTrusted ? fullScreenFrames(pid: pid) : []
        var covered = Set<String>()
        for screen in screens {
            let full = frames.contains { covers(screen, $0, reportedFullScreen: false) }
                || reported.contains { covers(screen, $0, reportedFullScreen: true) }
            if full { covered.insert(screen.panelID) }
        }
        return covered
    }

    /// Whether `window` fills `screen`.
    ///
    /// Exactly, for any window. Short by the camera housing only for a window the app itself
    /// reports as full screen: an ordinary window zoomed to fill the display under the menu
    /// bar has the very same frame, since the menu bar is as tall as the housing, and taking
    /// that for full screen would hide the island every time a window was zoomed.
    static func covers(_ screen: Screen, _ window: CGRect, reportedFullScreen: Bool) -> Bool {
        if screenCoversWindow(screen.rect, window) { return true }
        guard reportedFullScreen, screen.top > 0 else { return false }
        var below = screen.rect
        below.origin.y += screen.top
        below.size.height -= screen.top
        return screenCoversWindow(below, window)
    }

    static func screenCoversWindow(_ screen: CGRect, _ window: CGRect) -> Bool {
        abs(screen.width - window.width) < 2 && abs(screen.height - window.height) < 2 &&
        abs(screen.minX - window.minX) < 2 && abs(screen.minY - window.minY) < 2
    }

    /// The frames, in top-left screen coordinates, of the app's windows that say they are
    /// full screen. Empty without Accessibility access, or for an app that will not answer.
    private static func fullScreenFrames(pid: pid_t) -> [CGRect] {
        let application = AXUIElementCreateApplication(pid)
        // A game that has stopped answering must not hold the poll for the default six
        // seconds; a second is plenty for a window list.
        _ = AXUIElementSetMessagingTimeout(application, 1)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var fullValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullValue) == .success,
                  (fullValue as? Bool) == true else { return nil }
            return frame(of: window)
        }
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
}
