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
/// needed, and if any one of them is missing the island simply keeps AppKit's behaviour. The
/// lock screen is the one place the space must never show — the login window is drawn under
/// this level — so the space is hidden while the screen is locked and shown again on unlock.
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
    private var members: Set<Int> = []
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    private var cancellable: AnyCancellable?

    private init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setShown(false)
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setShown(true)
        })
        // The unlock notification is the one that shows the space again, and a space that
        // stays hidden is an island that never comes back. So every other way the Mac comes
        // back to the user is a chance to show it, once the session says it is unlocked.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if !ScreenLockMonitor.screenIsLocked { self?.setShown(true) }
            })
        }
        cancellable = Preferences.shared.$staysPutAcrossSpaces
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.setEnabled(enabled) }
    }

    /// Whether the island's space exists: the functions were found and the space was made.
    var isActive: Bool { space != 0 }

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

    /// Takes `window` back out, ahead of it being ordered out or closed.
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
        bridge.show(bridge.connection, [made] as CFArray)
        space = made
        IslandLog.panel.notice("island space \(made, privacy: .public) made")
        return bridge
    }

    private func setShown(_ shown: Bool) {
        guard let bridge, space != 0 else { return }
        if shown { bridge.show(bridge.connection, [space] as CFArray) } else { bridge.hide(bridge.connection, [space] as CFArray) }
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
        // Out of the space, but still on the list: switching the setting back on has to
        // find them again, and `release` forgets a window for good.
        for window in live where members.contains(window.windowNumber) {
            bridge.remove(bridge.connection, [window.windowNumber] as CFArray, [space] as CFArray)
        }
        bridge.hide(bridge.connection, [space] as CFArray)
        bridge.destroy(bridge.connection, space)
        space = 0
        members.removeAll()
    }
}
