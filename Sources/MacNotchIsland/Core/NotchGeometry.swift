import AppKit

/// Describes where the notch (real or simulated) sits on a given screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasPhysicalNotch: Bool
    /// The menu bar's height on this screen; a floating island hangs below it.
    var menuBarHeight: CGFloat = 24

    /// Detect the notch on a screen. Uses the safe-area inset for the height and the
    /// auxiliary menu-bar areas for the width, which is exact on every notched MacBook
    /// (including the 15-inch MacBook Air). Screens without a notch get a simulated one.
    /// Notch widths measured per screen, kept for moments when the system reports none.
    private static var measuredWidths: [String: CGFloat] = [:]

    /// `NOTCH_SIMULATE=1` in the environment makes a plain display behave as if it had a
    /// 200 x 32 pt notch, so the notch code paths can run on machines (and CI) without one.
    static var simulatesNotch: Bool { ProcessInfo.processInfo.environment["NOTCH_SIMULATE"] == "1" }

    static func detect(on screen: NSScreen, prefs: Preferences = .shared) -> NotchGeometry {
        var top = screen.safeAreaInsets.top
        if top == 0, simulatesNotch { top = 32 }
        let hasNotch = top > 0
        var width = automaticWidth(on: screen)
        var height: CGFloat = 32
        let menuBar = max(NSStatusBar.system.thickness, 24)
        // Which displays carry a menu bar is a system setting: every one of them with
        // "Displays have separate Spaces", the primary alone without it. A pill that hung
        // a menu bar's height below the top of a display that has no menu bar floated
        // twenty-eight points down with nothing above it.
        let hasMenuBar = NSScreen.screensHaveSeparateSpaces || isPrimary(screen)

        if hasNotch {
            height = top
        } else {
            // Simulated island on external displays: menu-bar height, iPhone-like proportions.
            height = max(menuBar, 30)
        }

        // An override exists for a notch the system under-reports. It may only enlarge the
        // island: a value below the measured cutout would put content under glass that is
        // not there.
        if prefs.notchWidthOverride > 0 { width = max(width, prefs.notchWidthOverride) }
        if prefs.notchHeightOverride > 0 { height = max(height, prefs.notchHeightOverride) }

        return NotchGeometry(screenFrame: screen.frame, notchWidth: width, notchHeight: height, hasPhysicalNotch: hasNotch,
                             menuBarHeight: hasNotch ? top : (hasMenuBar ? menuBar : 0))
    }

    /// The width the island takes on a screen before any override: the cutout where there is
    /// one, and the simulated island's where there is not. It is also where the Width slider
    /// in Settings starts, since an override can only ever widen it.
    static func automaticWidth(on screen: NSScreen) -> CGFloat {
        var top = screen.safeAreaInsets.top
        if top == 0, simulatesNotch { top = 32 }
        // Simulated island on external displays: iPhone-like proportions.
        guard top > 0 else { return 190 }
        let key = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "?"
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           case let w = screen.frame.width - left.width - right.width, w > 60 && w < 500 {
            measuredWidths[key] = w
            return w
        }
        // The auxiliary areas come and go with the menu bar; the cutout does not.
        return measuredWidths[key] ?? 200
    }

    /// What a value on the Width slider stores. At or under the width the island already has,
    /// an override would change nothing — it can only widen — so it is stored as Automatic,
    /// which is what it is.
    static func widthOverride(_ value: Double, automatic: Double) -> Double {
        value <= automatic ? 0 : value
    }

    /// Whether `screen` is the primary display — the one the Displays arrangement puts the
    /// menu bar on. By display number, not by object: AppKit hands out fresh `NSScreen`
    /// objects, so two of them for one display need not be the same instance.
    static func isPrimary(_ screen: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let first = NSScreen.screens.first else { return true }
        return (screen.deviceDescription[key] as? NSNumber) == (first.deviceDescription[key] as? NSNumber)
    }
}
