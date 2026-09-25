import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Three things the Mac does in one keystroke that nobody remembers the keystroke for: lock
/// the screen, put the display to sleep, and open the screenshot toolbar.
///
/// The lock is the call the menu bar's own Lock Screen item makes, looked up by name in a
/// private framework and walked past when it is not there, or when the screen has not locked
/// a couple of seconds after it, whatever it answered; behind it is Control-Command-Q, posted
/// as if typed, which needs Accessibility. The display goes to sleep through `pmset`, which
/// any user may run, and the toolbar is Apple's own Screenshot app.
enum SystemActions {
    /// Locks the screen at once, the way Control-Command-Q does.
    ///
    /// The menu's own call first, because it depends on nothing: no permission, no keyboard
    /// layout. The keystroke used to come first, and on a French keyboard it was
    /// Control-Command-A — see `lockKeyCode(characterFor:)` — which locks nothing; and since
    /// posting it counted as success, nothing else was tried. Whatever the call answers, the
    /// screen is given a couple of seconds to lock before the lock goes another way
    /// (`lockFallback`, `LockWatch`).
    static func lockScreen() {
        guard let lock = loginLockScreen else { return lockAnotherWay() }
        let status = lock()
        LockWatch.start { locked in
            guard Self.lockFallback(status: status, lockedAfter: locked) else { return }
            IslandLog.island.notice("the login framework answered \(status, privacy: .public) to a lock, and the screen did not lock")
            Self.lockAnotherWay()
        }
    }

    /// How long the screen is given to lock after the login framework's call, before the lock
    /// goes another way. The lock screen can take more than half a second to come up on a busy
    /// Mac, and half a second, as this was, pressed Control-Command-Q into a lock screen
    /// already on its way.
    static let lockPatience: TimeInterval = 2

    /// How often the session is read while waiting, for when the system's "locked"
    /// notification does not come.
    static let lockPollInterval: TimeInterval = 0.25

    /// Whether the lock goes another way: the keystroke, else the display put to sleep.
    ///
    /// `status` is what the login framework's call returned, nil when it is not there to call;
    /// `lockedAfter` is whether the screen locked within `lockPatience` of it. What the call
    /// returns is written down nowhere, so the screen decides, nought or not: locked in time,
    /// the call worked, whatever it said; not locked, it did not. A nought was believed at
    /// once for a while, because the screen was looked at after half a second and a session
    /// flag slow to turn had Control-Command-Q pressed into a lock screen on its way; the wait
    /// is two seconds now, and ends early on the system's own word that the screen is locked,
    /// so a nought that locked nothing is caught rather than believed. No call to make goes
    /// the other way at once.
    static func lockFallback(status: Int32?, lockedAfter: Bool) -> Bool {
        guard status != nil else { return true }
        return !lockedAfter
    }

    /// Waits up to `lockPatience` for the screen to lock and says, once, on the main thread,
    /// whether it did: at once on the system's own "screen is locked" notification, or on a
    /// read of the session every `lockPollInterval`, and no in the end. It keeps itself alive
    /// through its poll until it has answered.
    private final class LockWatch {
        private let done: (Bool) -> Void
        private let started = Date()
        private var observer: NSObjectProtocol?
        private var poll: Timer?
        private var heard = false

        static func start(_ done: @escaping (Bool) -> Void) {
            _ = LockWatch(done: done)
        }

        private init(done: @escaping (Bool) -> Void) {
            self.done = done
            observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                    self?.heard = true
                    self?.check()
                }
            // The timer holds the watch, and lets it go when it is invalidated.
            let poll = Timer(timeInterval: SystemActions.lockPollInterval, repeats: true) { [self] _ in check() }
            RunLoop.main.add(poll, forMode: .common)
            self.poll = poll
        }

        private func check() {
            guard let poll else { return }
            let locked = heard || ScreenLockMonitor.screenIsLocked
            guard locked || Date().timeIntervalSince(started) >= SystemActions.lockPatience else { return }
            poll.invalidate()
            self.poll = nil
            if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
            observer = nil
            done(locked)
        }
    }

    /// The lock without the login framework's call: Control-Command-Q, which needs
    /// Accessibility, else the display put to sleep.
    private static func lockAnotherWay() {
        if AXIsProcessTrusted(), postLockShortcut() { return }
        // Neither is open to us. Sleeping the display locks the Mac wherever "Require
        // password" is set to immediately, which is how most Macs ship; where it is not, the
        // display still goes dark, which is the half of a lock that can be seen.
        IslandLog.island.notice("no way to lock the screen; putting the display to sleep instead")
        sleepDisplay()
    }

    /// Turns the display off now. The Mac itself stays awake: music keeps playing, a download
    /// keeps going.
    static func sleepDisplay() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Opens the screenshot toolbar — Shift-Command-5 — with its choice of the whole screen, a
    /// window or a part, and its own recording buttons.
    static func openScreenshotToolbar() {
        // The island is not what anybody meant to take a picture of.
        ActivityCenter.shared.collapse(reason: "screenshot toolbar")
        let app = URL(fileURLWithPath: screenshotApp)
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            IslandLog.island.error("could not open Screenshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let screenshotApp = "/System/Applications/Utilities/Screenshot.app"

    // MARK: - The lock

    /// The key that types Q on the layout in force, or nil when no letter key does.
    ///
    /// Lock Screen is a menu item's key equivalent, and a key equivalent is matched by the
    /// character the key types, not by where the key sits: a virtual key code is a position,
    /// and position 0x0C, Q on a US keyboard, is A on a French one and ' on Dvorak. Posting it
    /// there was Control-Command-A. So the letter keys are asked, the US Q first since it is
    /// the answer nearly everywhere, and the first one that types "q" is the one pressed. A
    /// layout with no Q at all — Cyrillic, Greek — gets nil, and the lock goes another way
    /// rather than pressing something else. Pure, given what each key types, so the French
    /// keyboard can be tested on a US one.
    static func lockKeyCode(characterFor character: (Int) -> String?) -> CGKeyCode? {
        let candidates = [kVK_ANSI_Q] + HotKeyService.letterKeyCodes.filter { $0 != kVK_ANSI_Q }
        guard let code = candidates.first(where: { character($0)?.lowercased() == "q" }) else { return nil }
        return CGKeyCode(code)
    }

    static let lockFlags: CGEventFlags = [.maskControl, .maskCommand]

    /// Types Control-Command-Q into the system, with whichever key types Q here. Needs
    /// Accessibility, which the caller asks about first. Returns false when there is no Q to
    /// press or an event could not even be made; true means it was posted, which is as much as
    /// anybody can know about a keystroke.
    private static func postLockShortcut() -> Bool {
        guard let key = lockKeyCode(characterFor: KeyLayout.character(for:)) else {
            IslandLog.island.notice("no key types Q on this keyboard layout, so there is no lock keystroke to post")
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            IslandLog.island.error("could not make the lock keystroke")
            return false
        }
        down.flags = lockFlags
        up.flags = lockFlags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private typealias LockScreenImmediate = @convention(c) () -> Int32

    /// `SACLockScreenImmediate`, the call the menu bar's own Lock Screen item makes. It lives
    /// in a private framework and is not declared anywhere, so it is looked up by name, once;
    /// on a macOS that has moved or renamed it this is nil and the lock goes another way.
    private static let loginLockScreen: LockScreenImmediate? = {
        guard let handle = dlopen(loginFramework, RTLD_LAZY) else {
            IslandLog.island.notice("the login framework is not there")
            return nil
        }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            IslandLog.island.notice("the login framework has no SACLockScreenImmediate")
            return nil
        }
        return unsafeBitCast(symbol, to: LockScreenImmediate.self)
    }()

    static let loginFramework = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"

    // MARK: - Running a tool

    /// Runs a system tool and says so in the log when it fails. Nothing waits for it.
    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let name = (path as NSString).lastPathComponent
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            guard status != 0 else { return }
            IslandLog.island.error("\(name, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) failed with \(status, privacy: .public)")
        }
        do {
            try process.run()
        } catch {
            IslandLog.island.error("could not run \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
