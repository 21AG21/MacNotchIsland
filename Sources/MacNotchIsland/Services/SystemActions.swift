import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Three things the Mac does in one keystroke that nobody remembers the keystroke for: lock
/// the screen, put the display to sleep, and open the screenshot toolbar.
///
/// The lock is the call the menu bar's own Lock Screen item makes, looked up by name in a
/// private framework and walked past when it is not there; behind it is Control-Command-Q,
/// posted as if typed, which needs Accessibility. The display goes to sleep through `pmset`,
/// which any user may run, and the toolbar is Apple's own Screenshot app.
enum SystemActions {
    /// Locks the screen at once, the way Control-Command-Q does.
    ///
    /// The menu's own call first, because it depends on nothing: no permission, no keyboard
    /// layout, and it says whether it worked. The keystroke used to come first, and on a
    /// French keyboard it was Control-Command-A — see `lockKeyCode(characterFor:)` — which
    /// locks nothing; and since posting it counted as success, nothing else was tried.
    static func lockScreen() {
        if let lock = loginLockScreen {
            let status = lock()
            if status == 0 { return }
            IslandLog.island.notice("the login framework answered \(status, privacy: .public) to a lock")
        }
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
