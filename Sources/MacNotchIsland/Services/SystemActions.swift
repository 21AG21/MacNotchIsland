import AppKit
import ApplicationServices
import CoreGraphics

/// Three things the Mac does in one keystroke that nobody remembers the keystroke for: lock
/// the screen, put the display to sleep, and open the screenshot toolbar.
///
/// Each is done the most ordinary way there is. The lock is the Control-Command-Q every Mac
/// already answers, posted as if typed; the display goes to sleep through `pmset`, which any
/// user may run; the toolbar is Apple's own Screenshot app. Only where the ordinary way is
/// closed — no Accessibility, so no posting keys — does anything private come into it, and
/// then only by looking it up by name and walking past it when it is not there.
enum SystemActions {
    /// Locks the screen at once, the way Control-Command-Q does.
    static func lockScreen() {
        if AXIsProcessTrusted(), postLockShortcut() { return }
        if let lock = loginLockScreen {
            let status = lock()
            if status != 0 {
                IslandLog.island.notice("the login framework answered \(status, privacy: .public) to a lock")
            }
            return
        }
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

    /// Q's position on the keyboard, whatever the layout prints on it: the shortcut is a
    /// position, like every shortcut the system itself listens for.
    static let lockKeyCode: CGKeyCode = 0x0C
    static let lockFlags: CGEventFlags = [.maskControl, .maskCommand]

    /// Types Control-Command-Q into the system. Needs Accessibility, which is why it is asked
    /// about first; returns false when an event could not even be made.
    private static func postLockShortcut() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: lockKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: lockKeyCode, keyDown: false) else {
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
