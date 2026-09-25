import AppKit
import ApplicationServices
import Combine

/// Hides an island while an app has a window covering that island's whole display (full-screen
/// video, games, presentations). Polls the window list every 2 s, scaled by EnergyPolicy, and
/// only while the preference is on.
///
/// Per display. A film full screen on the external display hides that display's island and
/// leaves the MacBook's alone; one flag for every island hid the lot, and closed whatever
/// panel was open on a display the film was nowhere near.
///
/// Any app's windows, not only the frontmost app's. The film stays full screen on the external
/// display when a click on the MacBook brings Safari forward, and asking only the app in front
/// brought the external island back over the film within one poll. Every app's windows come
/// from the one window-list read there always was; the Accessibility question, a round trip to
/// the app asked, is put only to an app with a window that could be full screen on a notched
/// display, which is the one case the window list cannot settle (see `covers`).
///
/// But only a window at the front of its display, or the frontmost app's (`contenders`): a
/// utility that keeps a display-sized window behind everything else hid that display's island
/// for as long as it ran. Each window is at the front of one display at most, the one it
/// belongs to (`home`).
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
        // AppKit lookups on main; the window-list walk (every on-screen window) and the
        // Accessibility round trips off it.
        let screens = Self.screens()
        let trusted = AXIsProcessTrusted()
        let ignored = Self.ignoredPIDs()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // On screen only, which is also front to back: `contenders` reads the order.
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let seen = Self.windowList(list, ignoring: ignored)
            // Nil without Accessibility, which is what tells `coveredPanels` to go by the menu bar.
            var ask: ((pid_t) -> [CGRect])?
            if trusted { ask = { Self.fullScreenFrames(pid: $0) } }
            let covered = Self.coveredPanels(windows: seen.windows, menuBars: seen.menuBars, screens: screens,
                                             frontmost: frontmost, fullScreenFrames: ask)
            DispatchQueue.main.async { self?.apply(covered) }
        }
    }

    /// This app and the Finder, whose windows are never an app gone full screen over the island.
    private static func ignoredPIDs() -> Set<pid_t> {
        var pids: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
        for finder in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder") {
            pids.insert(finder.processIdentifier)
        }
        return pids
    }

    private func apply(_ covered: Set<String>) {
        guard timer != nil else { return }
        let center = ActivityCenter.shared
        guard center.fullscreenPanels != covered else { return }
        let newlyCovered = covered.subtracting(center.fullscreenPanels)
        center.fullscreenPanels = covered
        switch Self.forgetting(newlyCovered: newlyCovered, hover: center.hoverPanel, drag: center.dragPanel,
                               isOpen: center.isOpen, openPanel: center.openPanel,
                               allCovered: ActivityCenter.allHidden(live: center.livePanels, covered: covered)) {
        case .nothing: break
        case .forgetPointer: center.forgetPointer(on: newlyCovered)
        case .closeAll: center.clearInteraction(on: newlyCovered)
        }
    }

    /// What a display going full screen takes with it, see `forgetting`.
    enum Forgetting: Equatable {
        /// Nothing was happening on the islands just covered.
        case nothing
        /// The pointer, a drag or a press was on one of them: that is forgotten there, and
        /// every other island keeps its own, and the panel stays.
        case forgetPointer
        /// The panel goes: it was pinned on an island just covered, or open on every island
        /// and every one is covered now. The pointer is forgotten on those just covered.
        case closeAll
    }

    /// What a display going full screen takes with it. An island on a display the film is
    /// nowhere near keeps its panel, its hover and its drag: a yes or no used to forget the
    /// pointer on every island and close the panel with it, so the pointer resting on the
    /// external display's island as a film went full screen there closed the panel pinned
    /// on the MacBook.
    static func forgetting(newlyCovered: Set<String>, hover: String?, drag: String?,
                           isOpen: Bool, openPanel: String?, allCovered: Bool) -> Forgetting {
        guard !newlyCovered.isEmpty else { return .nothing }
        if isOpen {
            if let openPanel {
                if newlyCovered.contains(openPanel) { return .closeAll }
            } else if allCovered {
                return .closeAll
            }
        }
        if let hover, newlyCovered.contains(hover) { return .forgetPointer }
        if let drag, newlyCovered.contains(drag) { return .forgetPointer }
        return .nothing
    }

    /// One display as the window list sees it: the island it carries, its frame in
    /// CGWindowList's top-left coordinate space, and how much of its top edge a full-screen
    /// window leaves clear — the camera housing, on a display that has one.
    struct Screen: Equatable {
        var panelID: String
        var rect: CGRect
        var top: CGFloat
        /// Whether the display has a menu bar at all: every display with "Displays have
        /// separate Spaces", the primary alone without it. A menu bar that has gone is the
        /// fallback's evidence of full screen (see `covers`), which a display that never had
        /// one cannot give.
        var hasMenuBar = true
        /// Whether an island is on this display. One that carries none is never covered, but
        /// it is still listed: a window there belongs there (`home`), and without it a window
        /// against the shared edge would be given to the neighbour it overhangs.
        var carriesIsland = true
    }

    /// One window as the window list reports it: whose it is, and its frame in the list's
    /// top-left coordinate space.
    struct Window: Equatable {
        var pid: pid_t
        var frame: CGRect
        /// False for this app's windows and the Finder's: never an app gone full screen, but
        /// in front of one they can be, and then nothing behind them is full screen.
        var canCover = true
    }

    /// Every display, marked with whether it carries an island. Only those that do are ever
    /// covered: a film full screen on a display with no island used to count as an island
    /// hidden, and everything asked about no island in particular — the shortcut, the menu
    /// bar — answered "hidden". The others are listed so that their windows stay theirs.
    static func screens(carrying panels: Set<String> = ActivityCenter.shared.livePanels) -> [Screen] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { screen in
            let id = NotchPanel.panelID(for: screen)
            return Screen(panelID: id,
                          rect: CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                                       width: screen.frame.width, height: screen.frame.height),
                          top: screen.safeAreaInsets.top,
                          hasMenuBar: NSScreen.screensHaveSeparateSpaces || NotchGeometry.isPrimary(screen),
                          carriesIsland: panels.isEmpty || panels.contains(id))
        }
    }

    /// The processes whose windows are the system's own furniture rather than an app's: the
    /// Dock's, the window server's, the login window's. None of them is ever full screen.
    static let systemOwners: Set<String> = ["Dock", "Window Server", "loginwindow"]

    /// The menu bar is the window server's, one window per display that has one, at the main
    /// menu's level (`kCGMainMenuWindowLevel`).
    static let menuBarOwner = "Window Server"
    static let menuBarLayer = 24

    /// What one read of the window list holds: every app's ordinary windows, front to back as
    /// the list gives them, and where the menu bars are. An ordinary window is at layer 0, can
    /// be seen, and is not the system's. This app's and the Finder's (`ignoring`) are listed
    /// for where they stand, never as what covers a display (`Window.canCover`).
    ///
    /// A menu bar is known by its owner and its level, and by its name where the name can be
    /// read: the names of other processes' windows are withheld from an app without Screen
    /// Recording, so a missing name is taken for the menu bar's and only another name rules
    /// a window out.
    static func windowList(_ list: [[String: Any]], ignoring pids: Set<pid_t>) -> (windows: [Window], menuBars: [CGRect]) {
        var windows: [Window] = []
        var menuBars: [CGRect] = []
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            if owner == menuBarOwner, layer == menuBarLayer {
                let name = entry[kCGWindowName as String] as? String
                if name == nil || name == "Menubar" { menuBars.append(bounds) }
                continue
            }
            guard layer == 0, !systemOwners.contains(owner) else { continue }
            // A window nobody can see covers nothing, and is in front of nothing.
            guard ((entry[kCGWindowAlpha as String] as? Double) ?? 1) > 0 else { continue }
            windows.append(Window(pid: pid, frame: bounds, canCover: !pids.contains(pid)))
        }
        return (windows, menuBars)
    }

    /// The islands whose display some app covers with a window, from one read of the window
    /// list (`windowList`), front to back.
    ///
    /// A window that fills a display exactly covers it, whoever's it is, as long as it is at
    /// the front there (`contenders`). On a display with a camera housing a full-screen window
    /// stops below the housing — which is also exactly where a window zoomed under the menu bar
    /// stops, so such a window needs more than its frame: its app's own word, through
    /// Accessibility (`fullScreenFrames`, asked only of the apps that have one, each at most
    /// once), or, without Accessibility (`fullScreenFrames` nil), the display's menu bar having
    /// gone.
    static func coveredPanels(windows: [Window], menuBars: [CGRect], screens: [Screen], frontmost: pid_t?,
                              fullScreenFrames: ((pid_t) -> [CGRect])?) -> Set<String> {
        var answers: [pid_t: [CGRect]] = [:]
        var covered = Set<String>()
        for screen in screens where screen.carriesIsland {
            let inFront = contenders(on: screen, among: screens, windows: windows, frontmost: frontmost)
            if inFront.contains(where: { covers(screen, $0.frame, reportedFullScreen: false) }) {
                covered.insert(screen.panelID)
                continue
            }
            let candidates = inFront.filter { fillsBelowHousing(screen, $0.frame) }
            guard !candidates.isEmpty else { continue }
            if let fullScreenFrames {
                for pid in Set(candidates.map(\.pid)).sorted() {
                    let reported = answers[pid] ?? fullScreenFrames(pid)
                    answers[pid] = reported
                    if reported.contains(where: { covers(screen, $0, reportedFullScreen: true) }) {
                        covered.insert(screen.panelID)
                        break
                    }
                }
            } else {
                let menuBar = !screen.hasMenuBar || menuBarVisible(on: screen, menuBars: menuBars)
                if candidates.contains(where: { covers(screen, $0.frame, reportedFullScreen: false, menuBarVisible: menuBar) }) {
                    covered.insert(screen.panelID)
                }
            }
        }
        return covered
    }

    /// The windows that may be what covers `screen`: the ones belonging to the app whose window
    /// is at the front of that display, and the frontmost app's. `windows` is front to back.
    ///
    /// Any app's layer-0 window used to count, wherever it stood, so a utility that keeps a
    /// display-sized window behind everything — an overlay, a dimmer, a desktop of its own —
    /// hid that display's island for as long as it ran, with Safari in front of it. A
    /// full-screen app is at the front of its display, in a Space of its own; the frontmost
    /// app counts wherever its window stands, since whatever the user is in is not behind
    /// anything. The Finder and this app never cover a display (`Window.canCover`), but in
    /// front of one they can be, and then nothing behind them covers it.
    ///
    /// The front of a display is the first window that belongs to it (`home`), judged among
    /// every display in `screens`. The first window with two points of itself there used to
    /// be it, so a Safari window on the external display, against the shared edge and
    /// overhanging the MacBook by a few points, was the MacBook's front too, and the film full
    /// screen there came out from under its island.
    static func contenders(on screen: Screen, among screens: [Screen], windows: [Window], frontmost: pid_t?) -> [Window] {
        let front = windows.first(where: { home(of: $0.frame, among: screens) == screen.panelID })?.pid
        return windows.filter { $0.canCover && ($0.pid == front || $0.pid == frontmost) }
    }

    /// The display a window belongs to, by its `panelID`: of the displays it shows on at all
    /// (`isOn`), the one holding its centre, or, for a window whose centre is off every one
    /// of them, the one with most of it. Nil for a window that shows on none. One display
    /// each, so that the few points a window overhangs a neighbour by never make it the
    /// neighbour's too.
    static func home(of window: CGRect, among screens: [Screen]) -> String? {
        let showing = screens.filter { isOn($0, window) }
        let centre = CGPoint(x: window.midX, y: window.midY)
        if let holder = showing.first(where: { $0.rect.contains(centre) }) { return holder.panelID }
        func area(_ screen: Screen) -> CGFloat {
            let overlap = screen.rect.intersection(window)
            return overlap.width * overlap.height
        }
        return showing.max(by: { area($0) < area($1) })?.panelID
    }

    /// Whether a window shows on `screen` at all: more than a sliver of it lies there. A window
    /// parked off every display, or a point wide, is in front of nothing.
    static func isOn(_ screen: Screen, _ window: CGRect) -> Bool {
        let overlap = screen.rect.intersection(window)
        return !overlap.isNull && overlap.width >= 2 && overlap.height >= 2
    }

    /// Whether `window` fills `screen`.
    ///
    /// Exactly, for any window. Short by the camera housing only on better evidence than the
    /// frame: an ordinary window zoomed to fill the display under the menu bar has the very
    /// same frame, since the menu bar is as tall as the housing, and taking that for full
    /// screen would hide the island every time a window was zoomed. The evidence is the app
    /// reporting the window as full screen, or — for when the app cannot be asked, without
    /// Accessibility — the display's menu bar being gone: a full-screen Space takes it away,
    /// and a zoomed window leaves it where it is. `menuBarVisible` is true when the menu bar
    /// is not being used as evidence at all.
    static func covers(_ screen: Screen, _ window: CGRect, reportedFullScreen: Bool, menuBarVisible: Bool = true) -> Bool {
        if screenCoversWindow(screen.rect, window) { return true }
        guard reportedFullScreen || !menuBarVisible else { return false }
        return fillsBelowHousing(screen, window)
    }

    /// Whether `window` fills everything below the camera housing of a display that has one.
    static func fillsBelowHousing(_ screen: Screen, _ window: CGRect) -> Bool {
        guard screen.top > 0 else { return false }
        var below = screen.rect
        below.origin.y += screen.top
        below.size.height -= screen.top
        return screenCoversWindow(below, window)
    }

    /// Whether one of the menu bars the window list reports is on `screen`: along its top edge
    /// and within its width. A menu bar a full-screen Space has hidden is either not listed or
    /// listed above the display, out of sight, and is not on it.
    static func menuBarVisible(on screen: Screen, menuBars: [CGRect]) -> Bool {
        menuBars.contains { bar in
            bar.height > 0 && abs(bar.minY - screen.rect.minY) < 2
                && bar.midX > screen.rect.minX && bar.midX < screen.rect.maxX
        }
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
