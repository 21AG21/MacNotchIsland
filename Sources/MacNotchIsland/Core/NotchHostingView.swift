import AppKit
import SwiftUI

/// Hosting view that only accepts mouse events inside the island's current footprint so the
/// transparent canvas around it stays click-through (menu bar, windows below keep working).
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var hitSizeProvider: (() -> CGSize)?
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let provider = hitSizeProvider else { return super.hitTest(point) }
        let size = provider()
        let local = convert(point, from: superview)
        let rect: CGRect
        if isFlipped {
            rect = CGRect(x: bounds.midX - size.width / 2, y: 0, width: size.width, height: size.height)
        } else {
            rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height, width: size.width, height: size.height)
        }
        guard rect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
