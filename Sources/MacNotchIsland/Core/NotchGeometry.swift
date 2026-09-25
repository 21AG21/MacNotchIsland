import AppKit

/// Describes where the notch (real or simulated) sits on a given screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasPhysicalNotch: Bool
    /// The menu bar's height on this screen; a floating island hangs below it. Nothing where
    /// the display has no menu bar, or has one that hides itself (`menuBarHeight(notchTop:…)`).
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
        var height = automaticHeight(on: screen)
        let menuBar = max(NSStatusBar.system.thickness, 24)
        // Which displays carry a menu bar is a system setting: every one of them with
        // "Displays have separate Spaces", the primary alone without it. A pill that hung
        // a menu bar's height below the top of a display that has no menu bar floated
        // twenty-eight points down with nothing above it.
        let hasMenuBar = NSScreen.screensHaveSeparateSpaces || isPrimary(screen)
        let keptByMenuBar = Self.menuBarHeight(notchTop: top, carriesMenuBar: hasMenuBar,
                                               autoHides: Self.menuBarAutoHides, thickness: menuBar)

        // An override exists for a notch the system under-reports. It may only enlarge the
        // island: a value below the measured cutout would put content under glass that is
        // not there.
        if prefs.notchWidthOverride > 0 { width = max(width, prefs.notchWidthOverride) }
        if prefs.notchHeightOverride > 0 { height = max(height, prefs.notchHeightOverride) }

        return NotchGeometry(screenFrame: screen.frame, notchWidth: width, notchHeight: height, hasPhysicalNotch: hasNotch,
                             menuBarHeight: keptByMenuBar)
    }

    /// How much of the top of a display the menu bar keeps, for a floating island to hang
    /// below: the housing where there is a notch, whatever the menu bar does, since the
    /// cutout is there either way; otherwise the menu bar's thickness on a display that
    /// carries one, and nothing on a display that does not.
    ///
    /// Nor on one whose menu bar hides itself. The display was counted as carrying a menu bar
    /// whether or not one was showing, so with the menu bar set to hide, the pill still hung
    /// twenty-eight points down — under a menu bar that was not there, over windows that reach
    /// the top of the display. Now it hangs at the top, the way it does on a display with no
    /// menu bar.
    ///
    /// At the top is still 4 pt down (`IslandLayout.make`), and the edge above it is left to
    /// the menu bar: that is where the pointer goes to bring a hidden one down. The window
    /// takes the mouse only on the island's outline (`NotchPanel.passesThrough`), so the edge
    /// is never ours to hit-test; the ring it keeps a moment longer on a pointer leaving the
    /// pill (`NotchPanel.passThroughMargin`) reaches over it, but the menu bar comes down for
    /// the pointer being at the edge, not for the window under it, as it does over a
    /// full-screen window that reaches the top. Nothing there to move the pill further for.
    ///
    /// Measured when the panel is built, like the rest of this, so the setting is part of
    /// what the panels were built for (`NotchPanel.displayKey`), and switching it rebuilds
    /// them rather than leaving the pill where the old setting put it.
    static func menuBarHeight(notchTop: CGFloat, carriesMenuBar: Bool, autoHides: Bool, thickness: CGFloat) -> CGFloat {
        if notchTop > 0 { return notchTop }
        return carriesMenuBar && !autoHides ? thickness : 0
    }

    /// Whether the menu bar hides itself on the desktop: "Automatically hide and show the menu
    /// bar" set to Always or On Desktop Only, which macOS keeps as `_HIHideMenuBar` in the
    /// global domain. Only the desktop matters here — in a full-screen Space the menu bar is
    /// gone whatever this says, and the island with it (`FloatingDefaults.hidesInFullScreen`)
    /// — so `AppleMenuBarVisibleInFullscreen`, the other half of that setting, is not read.
    ///
    /// The setting rather than `visibleFrame` measured against `frame`: the panel is measured
    /// once, when it is built, and the setting is the same whatever is in front at that
    /// moment, where a measurement of the menu bar need not be.
    static var menuBarAutoHides: Bool {
        UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
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

    /// The height the island takes on a screen before any override: the cutout's where there
    /// is one, and the simulated island's where there is not — the menu bar's height, and
    /// never under 30. It is also where the Height slider in Settings starts, for the Width
    /// slider's reason: an override can only ever make the island taller.
    static func automaticHeight(on screen: NSScreen) -> CGFloat {
        var top = screen.safeAreaInsets.top
        if top == 0, simulatesNotch { top = 32 }
        guard top > 0 else { return max(max(NSStatusBar.system.thickness, 24), 30) }
        return top
    }

    /// What a value on the Height slider stores, by the Width slider's rule. The slider ran
    /// from nothing, and everything under the notch's own height did nothing at all — the
    /// fault Width had, left behind on the slider under it. At or under the height the
    /// island already has it is Automatic, which is what it is.
    static func heightOverride(_ value: Double, automatic: Double) -> Double {
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
