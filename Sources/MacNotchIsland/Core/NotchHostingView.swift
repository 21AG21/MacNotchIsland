import AppKit
import SwiftUI

/// The panel's content view: a plain view with no size of its own, so the window is exactly
/// as large as the panel says and never as large as the SwiftUI content would like. The
/// hosting view sits inside it, where it may be wider than the window (see `NotchPanel.place`)
/// without dragging the window along. Clicks that miss the island fall through.
final class NotchContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return nil
    }
}

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

    /// The island's footprint in this view's own coordinates, or nil when no extents are
    /// known. This view is kept centred on the notch by its panel, so `bounds.midX` is the notch.
    func islandRect() -> CGRect? {
        guard let provider = hitExtentsProvider else { return nil }
        let e = provider()
        let width = e.leading + e.trailing
        if isFlipped {
            return CGRect(x: bounds.midX - e.leading, y: 0, width: width, height: e.height)
        }
        return CGRect(x: bounds.midX - e.leading, y: bounds.maxY - e.height, width: width, height: e.height)
    }

    /// Whether a point in window coordinates lies on the island. Pure geometry: nothing here
    /// asks SwiftUI anything, so it is safe to call from any callback at any moment.
    func islandContains(windowPoint: NSPoint) -> Bool {
        guard let rect = islandRect() else { return bounds.contains(convert(windowPoint, from: nil)) }
        return rect.contains(convert(windowPoint, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let rect = islandRect() else { return super.hitTest(point) }
        guard rect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}
