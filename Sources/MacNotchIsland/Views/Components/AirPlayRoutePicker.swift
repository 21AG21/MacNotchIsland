import AppKit
import AVKit
import SwiftUI

/// The system's own AirPlay route picker — the glyph that drops Control Centre's list of
/// HomePods, Apple TVs and speakers — for the Sound column's last row. Public AVKit, and the way
/// to AirPlay that keeps working whatever the AirPlay device does or does not list as its data
/// sources, which is undocumented. Borderless and white, so it reads as one of the island's own
/// glyphs rather than as a stray AppKit control.
///
/// Not drawn in the gallery: `ImageRenderer` cannot draw an AppKit view, and would put a yellow
/// block with a red line through it where the glyph goes. See `RenderMode`.
struct AirPlayRoutePicker: NSViewRepresentable {
    /// Keeps hold of the picker so the row around it can press it too.
    let handle: AirPlayRouteHandle

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        for state in [AVRoutePickerView.ButtonState.normal, .normalHighlighted, .active, .activeHighlighted] {
            picker.setRoutePickerButtonColor(.white, for: state)
        }
        picker.setAccessibilityLabel("AirPlay")
        handle.view = picker
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        handle.view = picker
    }
}

/// The route picker, reachable from outside it: a click anywhere on its row opens the same list
/// the glyph does, not only a click on the glyph itself.
final class AirPlayRouteHandle {
    weak var view: AVRoutePickerView?

    /// Presses the picker's own button. AVKit offers no call for opening the list, so this finds
    /// the button the picker is drawn with; a picker built some other way is logged and left to
    /// be clicked directly.
    func open() {
        guard let view else { return }
        guard let button = Self.button(in: view) else {
            IslandLog.audio.notice("the AirPlay route picker has no button to press; click its glyph")
            return
        }
        button.performClick(nil)
    }

    private static func button(in view: NSView) -> NSButton? {
        for sub in view.subviews {
            if let direct = sub as? NSButton { return direct }
            if let nested = Self.button(in: sub) { return nested }
        }
        return nil
    }
}
