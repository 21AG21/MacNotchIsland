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
    static func detect(on screen: NSScreen, prefs: Preferences = .shared) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        let hasNotch = top > 0
        var width: CGFloat = 200
        var height: CGFloat = 32

        if hasNotch {
            height = top
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let w = screen.frame.width - left.width - right.width
                if w > 60 && w < 500 { width = w }
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
