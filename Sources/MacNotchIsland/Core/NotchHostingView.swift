import AppKit
import SwiftUI

/// Hosting view that only accepts mouse events inside the island's current footprint so the
/// transparent canvas around it stays click-through (menu bar, windows below keep working).
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// The island's reach from the notch centre: left, right, and down from the top edge.
    var hitExtentsProvider: (() -> (leading: CGFloat, trailing: CGFloat, height: CGFloat))?
    /// Which panel (screen) this view belongs to; gestures are routed per panel.
    var panelID: String = "main"

    /// Controls inside the island react to the first click even when the panel isn't key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        ActivityCenter.shared.setPressed(true, panel: panelID)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        ActivityCenter.shared.setPressed(false, panel: panelID)
    }

    /// A context menu takes the pointer off the island; hold the panel open while it's up.
    override func rightMouseDown(with event: NSEvent) {
        ActivityCenter.shared.holdOpen(for: 15)
        super.rightMouseDown(with: event)
    }

    /// Trackpad gestures arrive here as scroll events. Anything the router does not claim is
    /// passed on, so scrollable SwiftUI content (clipboard list, shelf strip) still scrolls.
    override func scrollWheel(with event: NSEvent) {
        guard !GestureRouter.shared.handle(event, panel: panelID) else { return }
        super.scrollWheel(with: event)
    }

    /// This view is kept centred on the notch by its panel, so `bounds.midX` is the notch.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let provider = hitExtentsProvider else { return super.hitTest(point) }
        let e = provider()
        let local = convert(point, from: superview)
        let width = e.leading + e.trailing
        let rect: CGRect
        if isFlipped {
            rect = CGRect(x: bounds.midX - e.leading, y: 0, width: width, height: e.height)
        } else {
            rect = CGRect(x: bounds.midX - e.leading, y: bounds.maxY - e.height, width: width, height: e.height)
        }
        guard rect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
