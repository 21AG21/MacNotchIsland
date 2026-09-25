import AppKit

/// What two switches start at on a Mac whose island floats, until somebody sets them.
///
/// Every default in Preferences was chosen with a notch in mind, and two of them are wrong
/// without one. Under a notch the island is the camera housing: the strip it sits in is dead
/// space nobody points at, and a full-screen film is drawn around the housing, not under it.
/// On a display without a notch the island is a pill hung over the top of whatever is in
/// front — Safari's tabs, a toolbar, the top of a film — so a pointer resting there is on its
/// way to a tab, not asking for Home, and a pill left over a full-screen video is a black
/// mark across the top of the picture.
///
/// Only a switch nobody has set follows the island: `stored` is nil while `object(forKey:)`
/// finds nothing, the test the shortcut's default is read by, and a switch that follows is
/// not written down (`Preferences.followFloatingDefaults`). Once it has been set, either way,
/// it is the user's and stays as they left it on every display.
enum FloatingDefaults {
    /// Whether the island hides while an app is full screen. Off under a notch, where the
    /// island sits beside the camera and a full-screen window is drawn below it. On where it
    /// floats: the panel is at the main menu's level and joins full-screen Spaces, so without
    /// this it stays over every full-screen video — and on a display without a notch, telling
    /// full screen apart needs no Accessibility, since a full-screen window there is the
    /// display's whole frame (`FullscreenMonitor.covers`).
    static func hidesInFullScreen(stored: Bool?, floating: Bool) -> Bool {
        stored ?? floating
    }

    /// Whether resting the pointer on the island opens the panel with nothing live on it —
    /// "Open from the empty notch too". On under a notch, where nothing else is there to be
    /// pointed at. Off where the island floats: resting on the bare pill for a quarter of a
    /// second opened Home over the tab the pointer was going to. A live activity still opens
    /// under the pointer (`ActivityCenter.peeksWhenIdle`), and a click on the bare pill still
    /// opens Home (`ActivityCenter.tap`).
    static func idleHoverOpens(stored: Bool?, floating: Bool) -> Bool {
        stored ?? !floating
    }

    /// Whether the island floats everywhere it is, given whether each display has a notch:
    /// true only where none of them has one. Nil with no displays to go by: a display that
    /// has not come back yet says nothing about the island.
    ///
    /// Every island, not any. The two switches are one pair for every island, and a notch
    /// among the displays keeps the notch's defaults — with "Show on all displays" off the
    /// island is on the notch alone (`AppDelegate.targetScreens`), and with it on the notch
    /// still carries one. Any island used to be enough, so a MacBook with a monitor and that
    /// switch on had its notch island hide in full screen and stop opening under a resting
    /// pointer, and both flipped each time the monitor was plugged in or out. So "Show on all
    /// displays" decides nothing here: a Mac floats its island out of the box only when it has
    /// no notch to sit in, the lid shut on a MacBook included.
    static func floats(notched: [Bool]) -> Bool? {
        guard !notched.isEmpty else { return nil }
        return !notched.contains(true)
    }

    /// The same, from this Mac's displays, for Preferences to start from before any panel has
    /// been built. Not `NotchGeometry.detect`, which reads Preferences and would be asking the
    /// preferences that are being loaded. A notch `NOTCH_SIMULATE` puts on a plain display
    /// counts, as it does there. No displays at all reads as the notch's defaults, which were
    /// every Mac's before this.
    static func floatsOnThisMac() -> Bool {
        let notched = NSScreen.screens.map { $0.safeAreaInsets.top > 0 || NotchGeometry.simulatesNotch }
        return floats(notched: notched) ?? false
    }
}
