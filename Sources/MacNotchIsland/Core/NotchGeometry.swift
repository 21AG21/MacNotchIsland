import AppKit

/// Describes where the notch (real or simulated) sits on a given screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasPhysicalNotch: Bool

    var notchSize: CGSize { CGSize(width: notchWidth, height: notchHeight) }

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
        var width: CGFloat = 200
        var height: CGFloat = 32

        if hasNotch {
            height = top
            let key = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "?"
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               case let w = screen.frame.width - left.width - right.width, w > 60 && w < 500 {
                width = w
                measuredWidths[key] = w
            } else if let known = measuredWidths[key] {
                // The auxiliary areas come and go with the menu bar; the cutout does not.
                width = known
            } else if simulatesNotch {
                width = 200
            }
        } else {
            // Simulated island on external displays: menu-bar height, iPhone-like proportions.
            let menuBar = max(NSStatusBar.system.thickness, 24)
            height = max(menuBar, 30)
            width = 190
        }

        // An override exists for a notch the system under-reports. It may only enlarge the
        // island: a value below the measured cutout would put content under glass that is
        // not there.
        if prefs.notchWidthOverride > 0 { width = max(width, prefs.notchWidthOverride) }
        if prefs.notchHeightOverride > 0 { height = max(height, prefs.notchHeightOverride) }

        return NotchGeometry(screenFrame: screen.frame, notchWidth: width, notchHeight: height, hasPhysicalNotch: hasNotch)
    }
}
