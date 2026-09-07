import AppKit
import SwiftUI

/// Hosting view that only accepts mouse events inside the island's current footprint so the
/// transparent canvas around it stays click-through (menu bar, windows below keep working).
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var hitSizeProvider: (() -> CGSize)?

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
