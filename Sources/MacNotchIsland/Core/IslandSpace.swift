import AppKit
import Combine

/// A window space of the island's own, so a Space transition leaves it exactly where it is.
///
/// `.canJoinAllSpaces` puts a window in every Space and `.stationary` keeps it out of Mission
/// Control's shuffle; neither keeps it out of the transition itself. A swipe between desktops,
/// or into or out of a full-screen app, slides the whole window layer sideways, and the
/// island slid with it and snapped back afterwards — the one thing a part of the machine must
/// never do. The window server does have a place for windows that take no part: a space of
/// their own at an absolute level above every desktop, which is where the menu bar's own
/// windows live. Making one is not public API. The functions are SkyLight's, re-exported by
/// CoreGraphics under their `CGS` names, unchanged since 10.9, and every app of this kind
/// that stays put uses them.
///
/// Nothing here is trusted to exist. Each function is looked up by name the first time it is
/// needed, and if any one of them is missing the island simply keeps AppKit's behaviour.
///
/// Whether the window server draws a space's level above every window of every other space,
/// or only consults it for the transition, is written down nowhere, so the space is made safe
/// under either reading. It never shows over the login window or a screen saver, both of which
/// are drawn under this level: it is hidden while the screen is locked and while the screen
/// saver runs, a space made while the screen is locked — the app launched at the lock screen
/// by a script's alert — starts hidden, and it is shown again only once the session is
/// unlocked and the saver has stopped (`shows`). And what the island opens goes in with it for
/// as long as it is up, so it is never drawn under the island it came from: a popover, which
/// AppKit attaches to the panel as a child window (`adoptChild`), and a menu's windows while
/// the menu tracks (`menuBegan`).
///
/// The whole thing can be switched off in Settings, for a display arrangement it turns out
/// not to suit.
final class IslandSpace {
    static let shared = IslandSpace()

    private typealias ConnectionID = Int32
    private typealias SpaceID = UInt64
    private typealias MainConnection = @convention(c) () -> ConnectionID
    private typealias SpaceCreate = @convention(c) (ConnectionID, Int32, CFDictionary?) -> SpaceID
    private typealias SpaceDestroy = @convention(c) (ConnectionID, SpaceID) -> Void
    private typealias SpaceSetLevel = @convention(c) (ConnectionID, SpaceID, Int32) -> Void
    private typealias SpacesShow = @convention(c) (ConnectionID, CFArray) -> Void
    private typealias WindowsAndSpaces = @convention(c) (ConnectionID, CFArray, CFArray) -> Void

    /// The window server's functions, found by name.
    private struct Bridge {
        let connection: ConnectionID
        let create: SpaceCreate
        let destroy: SpaceDestroy
        let setLevel: SpaceSetLevel
        let show: SpacesShow
        let hide: SpacesShow
        let add: WindowsAndSpaces
        let remove: WindowsAndSpaces

        /// Every symbol, or nothing: a space that can be made but not shown, or shown but
        /// never given a window, is worse than none.
        static func load() -> Bridge? {
            guard let main: MainConnection = symbol("CGSMainConnectionID"),
                  let create: SpaceCreate = symbol("CGSSpaceCreate"),
                  let destroy: SpaceDestroy = symbol("CGSSpaceDestroy"),
                  let setLevel: SpaceSetLevel = symbol("CGSSpaceSetAbsoluteLevel"),
                  let show: SpacesShow = symbol("CGSShowSpaces"),
                  let hide: SpacesShow = symbol("CGSHideSpaces"),
                  let add: WindowsAndSpaces = symbol("CGSAddWindowsToSpaces"),
                  let remove: WindowsAndSpaces = symbol("CGSRemoveWindowsFromSpaces") else { return nil }
            return Bridge(connection: main(), create: create, destroy: destroy, setLevel: setLevel,
                          show: show, hide: hide, add: add, remove: remove)
        }

        private static func symbol<T>(_ name: String) -> T? {
            // RTLD_DEFAULT: every image the process has loaded, CoreGraphics among them.
            guard let handle = UnsafeMutableRawPointer(bitPattern: -2), let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: T.self)
        }
    }

    /// The level the space sits at: the top. The menu bar's own windows are at 24 or so and
    /// the island's window level is a few above that; the space's level is what the Space
    /// transition looks at, and the top is where nothing slides.
    static let level = Int32.max
    /// The one space type that works: any other and the Finder decides the new space is a
    /// desktop of its own and draws its icons on it.
    private static let userSpaceType: Int32 = 1

    private var bridge: Bridge?
    private var space: SpaceID = 0
    /// The island panels in the space, by window number.
    private var members: Set<Int> = []
    /// The panels themselves, so switching the setting back on can find them again.
    private let windows = NSHashTable<NSWindow>.weakObjects()
    /// Windows a panel opened that ride in the space while they are up: its popovers, by
    /// window number, and a tracking menu's windows. Kept apart from `members` and from
    /// `windows`, so letting one of them go can never take a panel out of the space.
    private var children: Set<Int> = []
    private var menuWindows: Set<Int> = []
    private var observers: [NSObjectProtocol] = []
    private var cancellable: AnyCancellable?
    /// Between the screen saver's start and its stop.
    private var screenSaverRunning = false
    /// Whether the space was last shown rather than hidden, for the diagnostics report.
    private(set) var isShown = false
    /// Looks for a tracking menu's windows, see `menuBegan`.
    private var menuPoll: Timer?
    private var menuPollIdleTicks = 0

    private init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setShown(false)
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            // Nobody unlocks a screen through a running screen saver: whatever it was, it is
            // over, and a flag left standing here would keep the island away for good.
            self?.screenSaverRunning = false
            self?.setShown(true)
        })
        // The screen saver is drawn under this level exactly as the login window is, and the
        // saver starts on its own — with no lock at all when no password is asked for.
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            self?.screenSaverRunning = true
            self?.setShown(false)
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            // A saver that asks for the password on its way out leaves the lock screen up, and
            // the unlock is what shows the space then.
            self?.screenSaverRunning = false
            self?.showIfAllowed()
        })
        // The unlock notification is the one that shows the space again, and a space that
        // stays hidden is an island that never comes back. So every other way the Mac comes
        // back to the user is a chance to show it, once the session says it is unlocked.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // A Mac waking from sleep is showing no screen saver, whatever was last heard.
                if note.name == NSWorkspace.didWakeNotification { self?.screenSaverRunning = false }
                self?.showIfAllowed()
            })
        }
        let local = NotificationCenter.default
        observers.append(local.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuBegan()
        })
        observers.append(local.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuEnded()
        })
        cancellable = Preferences.shared.$staysPutAcrossSpaces
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.setEnabled(enabled) }
    }

    /// Whether the island's space exists: the functions were found and the space was made.
    var isActive: Bool { space != 0 }

    /// Whether the space may be on screen: never over the login window, never over a screen
    /// saver. The one question behind every show — the space being made, the unlock, the
    /// saver stopping, the Mac waking — so none of them can answer it differently.
    ///
    /// Being made is where it was missing. The space was shown the moment it was made, and it
    /// is made when the first panel is ordered in: an app that was not running, launched at
    /// the lock screen by a script's `notchctl alert`, drew its card over the login window.
    static func shows(locked: Bool, screenSaverRunning: Bool) -> Bool {
        !locked && !screenSaverRunning
    }

    /// Puts `window` in the island's space. Idempotent, and nothing if the setting is off or
    /// the window server has no such thing.
    func adopt(_ window: NSWindow) {
        windows.add(window)
        guard Preferences.shared.staysPutAcrossSpaces, let bridge = prepared() else { return }
        let number = window.windowNumber
        guard number > 0, !members.contains(number) else { return }
        bridge.add(bridge.connection, [number] as CFArray, [space] as CFArray)
        members.insert(number)
    }

    /// Takes `window` back out, once it has been ordered out or closed. That order is
    /// `NotchPanel`'s, and it is the right one: a window taken out of the space while still on
    /// screen falls back into the desktop's layer for a frame before it goes, and a window
    /// that has only been ordered out keeps its window number, so it can still be named here.
    func release(_ window: NSWindow) {
        windows.remove(window)
        let number = window.windowNumber
        guard let bridge, space != 0, members.contains(number) else { return }
        bridge.remove(bridge.connection, [number] as CFArray, [space] as CFArray)
        members.remove(number)
    }

    /// The space, made on first use.
    private func prepared() -> Bridge? {
        if space != 0 { return bridge }
        if bridge == nil { bridge = Bridge.load() }
        guard let bridge else {
            IslandLog.panel.notice("no window-server space functions; the island keeps AppKit's spaces")
            return nil
        }
        let made = bridge.create(bridge.connection, Self.userSpaceType, nil)
        guard made != 0 else {
            IslandLog.panel.error("the window server refused an island space")
            return nil
        }
        bridge.setLevel(bridge.connection, made, Self.level)
        space = made
        // Hidden outright rather than merely not shown, whatever a new space's default is:
        // the unlock, or the saver's stop, shows it when the time comes.
        let shown = Self.shows(locked: ScreenLockMonitor.screenIsLocked, screenSaverRunning: screenSaverRunning)
        setShown(shown)
        IslandLog.panel.notice("island space \(made, privacy: .public) made\(shown ? "" : ", hidden until the screen is unlocked", privacy: .public)")
        return bridge
    }

    private func setShown(_ shown: Bool) {
        guard let bridge, space != 0 else { return }
        if shown { bridge.show(bridge.connection, [space] as CFArray) } else { bridge.hide(bridge.connection, [space] as CFArray) }
        isShown = shown
    }

    /// Shows the space if nothing it must not cover is up.
    private func showIfAllowed() {
        guard Self.shows(locked: ScreenLockMonitor.screenIsLocked, screenSaverRunning: screenSaverRunning) else { return }
        setShown(true)
    }

    // MARK: - What the island opens

    /// Puts a window a panel has just attached as a child — a popover, which AppKit hangs off
    /// the window of the view it points at — in the space with the panel. Left on AppKit's
    /// spaces, it is a window below this level, and under a window server that draws the
    /// space's level above everything else the popover opened under the island it came from.
    ///
    /// Nothing at all unless the space is already there: a popover is never a reason to make
    /// one. A panel is not a child and is left to its own ordering.
    func adoptChild(_ window: NSWindow) {
        guard !(window is NotchPanel), space != 0 else { return }
        let number = window.windowNumber
        guard number > 0 else {
            // Not on the window server yet; it will be by the next turn.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, window.parent is NotchPanel, window.windowNumber > 0 else { return }
                self.join(window.windowNumber, into: &self.children)
            }
            return
        }
        join(number, into: &children)
    }

    /// Takes a child back out once it is detached. One still on screen is taken out on the next
    /// turn, by when it has been ordered out, so it is never seen dropping under the island on
    /// its way off; and not at all if a panel has taken it back meanwhile.
    func releaseChild(_ window: NSWindow) {
        guard !(window is NotchPanel), space != 0 else { return }
        let number = window.windowNumber
        guard window.isVisible else { return leave(number, from: &children) }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, !(window?.parent is NotchPanel) else { return }
            self.leave(number, from: &self.children)
        }
    }

    /// In the space, asked of the window server every time: a window ordered out and back in
    /// is back in AppKit's spaces alone, and nothing tells the list here that it left.
    private func join(_ number: Int, into set: inout Set<Int>) {
        guard let bridge, space != 0, number > 0 else { return }
        bridge.add(bridge.connection, [number] as CFArray, [space] as CFArray)
        set.insert(number)
    }

    private func leave(_ number: Int, from set: inout Set<Int>) {
        guard let bridge, space != 0, set.remove(number) != nil else { return }
        bridge.remove(bridge.connection, [number] as CFArray, [space] as CFArray)
    }

    /// How often a tracking menu's windows are looked for: a submenu opens whenever the pointer
    /// reaches its item, and a window that joins late is drawn under the island until it does.
    static let menuPollInterval: TimeInterval = 0.05
    /// How long the look goes on with nothing to find. A menu is on screen for as long as it
    /// tracks, so this only ends a look whose end of tracking never came.
    static let menuPollGiveUp: TimeInterval = 1

    /// A menu opened from the island — its right-click menu, the shelf's, a window tile's, the
    /// keyboard disc's — is a set of this app's windows above the panel's level, on AppKit's
    /// spaces and attached to nothing. So while any menu of this app tracks, the windows it has
    /// on screen are in the space, and they come out when it stops. The menu's windows are not
    /// on screen yet when tracking begins, and a submenu comes later, hence the look every few
    /// frames rather than once. Cheap for as long as a menu is open, and nothing otherwise.
    private func menuBegan() {
        guard space != 0 else { return }
        menuPollIdleTicks = 0
        syncMenuWindows()
        guard menuPoll == nil else { return }
        // Common modes: a menu tracks in the event-tracking mode, where a default-mode timer
        // never fires.
        let timer = Timer(timeInterval: Self.menuPollInterval, repeats: true) { [weak self] _ in self?.menuPollTick() }
        RunLoop.main.add(timer, forMode: .common)
        menuPoll = timer
    }

    private func menuPollTick() {
        let found = syncMenuWindows()
        menuPollIdleTicks = found ? 0 : menuPollIdleTicks + 1
        if Double(menuPollIdleTicks) * Self.menuPollInterval >= Self.menuPollGiveUp { stopMenuPoll() }
    }

    private func menuEnded() {
        stopMenuPoll()
        for number in menuWindows { leave(number, from: &menuWindows) }
        menuWindows.removeAll()
    }

    private func stopMenuPoll() {
        menuPoll?.invalidate()
        menuPoll = nil
    }

    /// Brings the space's list of menu windows in line with what is on screen: in with any
    /// that have appeared, out with any that have gone. Whether anything was found.
    @discardableResult
    private func syncMenuWindows() -> Bool {
        guard space != 0 else { return false }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let shown = Self.menuWindowNumbers(in: list, pid: ProcessInfo.processInfo.processIdentifier,
                                           above: NotchPanel.islandLevel.rawValue)
            .subtracting(members).subtracting(children)
        for number in menuWindows.subtracting(shown) { leave(number, from: &menuWindows) }
        for number in shown.subtracting(menuWindows) { join(number, into: &menuWindows) }
        return !shown.isEmpty
    }

    /// The windows of this process a menu has on screen, from window-list entries: ours, and
    /// above the island's own level, which a window has to be to be drawn over the island at
    /// all. Nothing below it needs to join — it is under the island whichever way the window
    /// server reads the space's level — and that keeps out everything that must not: a
    /// Settings window, which would otherwise be lifted over every other app's windows for as
    /// long as a menu was open, and the status item, whose window is at the menu bar's level.
    static func menuWindowNumbers(in list: [[String: Any]], pid: pid_t, above level: Int) -> Set<Int> {
        var numbers = Set<Int>()
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer > level,
                  let number = window[kCGWindowNumber as String] as? Int, number > 0 else { continue }
            numbers.insert(number)
        }
        return numbers
    }

    /// The setting changed: every island window goes in, or every one comes out and the
    /// space is torn down, so switching it off leaves nothing behind.
    private func setEnabled(_ enabled: Bool) {
        let live = windows.allObjects
        if enabled {
            for window in live where window.isVisible { adopt(window) }
            return
        }
        guard let bridge, space != 0 else { return }
        stopMenuPoll()
        // Out of the space, but still on the list: switching the setting back on has to
        // find them again, and `release` forgets a window for good. Every number the space
        // holds goes, a panel's or not, so nothing is left in a space that no longer exists.
        for number in members.union(children).union(menuWindows) {
            bridge.remove(bridge.connection, [number] as CFArray, [space] as CFArray)
        }
        bridge.hide(bridge.connection, [space] as CFArray)
        bridge.destroy(bridge.connection, space)
        space = 0
        isShown = false
        members.removeAll()
        children.removeAll()
        menuWindows.removeAll()
    }
}
