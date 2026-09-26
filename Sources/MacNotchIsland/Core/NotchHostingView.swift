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

/// Hosting view that only accepts mouse events inside the island's drawn outline so the
/// transparent canvas around it stays click-through (menu bar, windows below keep working).
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// The island's layout right now, or nil while nothing is drawn (the island is hidden).
    /// The outline is built from it: the body's own shape, ears and all, plus the bubble's
    /// circle when there is one — never a rectangle round them. The rectangle reached thirty
    /// points past an open panel's sides (the ears' width, which only exists at the very top)
    /// and down into its rounded corners, and a click there to dismiss the panel was taken by
    /// the window and hit nothing, so the panel stayed and a second click was needed.
    var islandLayoutProvider: (() -> IslandLayout?)?
    /// Which panel (screen) this view belongs to; gestures are routed per panel.
    var panelID: String = "main"
    /// The last outline built, for each of the two ways of asking for one. See `OutlineCache`.
    private var outlines = OutlineCache()

    /// Controls inside the island react to the first click even when the panel isn't key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The press-in is the body's alone. A click on the bubble pressed the pill beside it in,
    /// as if the click had landed on the pill: feedback on the one thing not being clicked.
    ///
    /// And the collapsed island's alone (`IslandPress.publishes`). Open, the press is not told
    /// as a press-in, only as the press that pins a peek, which `setPressed` also did.
    override func mouseDown(with event: NSEvent) {
        if islandContains(windowPoint: event.locationInWindow, includingBubble: false) {
            let expanded = islandLayoutProvider?()?.isExpanded ?? false
            if IslandPress.publishes(expanded: expanded) {
                ActivityCenter.shared.setPressed(true, panel: panelID)
            } else {
                ActivityCenter.shared.pinPeek(panel: panelID)
            }
        }
        super.mouseDown(with: event)
    }

    /// Cleared whatever the press landed on, so nothing can be left pressed in. Nothing is
    /// published when nothing was pressed (`setPressed` sets only a change).
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

    /// The island's outline in this view's own top-left coordinates, or nil when nothing is
    /// drawn. This view is kept centred on the notch by its panel, so `bounds.midX` is the
    /// notch.
    ///
    /// Asked two or three times for every move of the pointer across the canvas, and the
    /// island between moves is almost always the one it was: the outline is built once for a
    /// layout and kept until the layout, the bounds or the question changes. The layout itself
    /// is still asked for every time, so a change the provider sees is never answered with an
    /// outline that was built before it.
    func islandPath(includingBubble: Bool = true) -> Path? {
        guard let layout = islandLayoutProvider?() else { return nil }
        let key = OutlineCache.Key(layout: layout, bounds: bounds, includingBubble: includingBubble)
        return outlines.outline(for: key) {
            Self.outline(of: $0.layout, in: $0.bounds, includingBubble: $0.includingBubble)
        }
    }

    /// The outline `IslandRootView` draws for `layout`, in a top-left space of `bounds`
    /// centred on the notch: the body shifted by `bodyShift`, hanging `topInset` below the
    /// top, and the bubble a gap to its right. The bubble can be left out: a click on it is
    /// a click, but a pointer resting on it is not a hover — hovering opens a peek, and the
    /// peek's layout has no bubble, so the thing being pointed at went away before it could
    /// be clicked.
    nonisolated static func outline(of layout: IslandLayout, in bounds: CGRect, includingBubble: Bool = true) -> Path {
        let width = layout.frameWidth
        let body = CGRect(x: bounds.midX + layout.bodyShift - width / 2, y: bounds.minY + layout.topInset,
                          width: width, height: layout.bodyHeight)
        var path = NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius, floating: layout.floating)
            .path(in: body)
        if layout.hasBubble, includingBubble {
            let d = layout.bubbleDiameter
            path.addEllipse(in: CGRect(x: body.maxX + layout.bubbleGap, y: body.minY, width: d, height: d))
        }
        return path
    }

    /// Whether `point` is on the outline, or within `margin` of its edge.
    nonisolated static func contains(_ path: Path, _ point: CGPoint, margin: CGFloat) -> Bool {
        if path.contains(point) { return true }
        guard margin > 0 else { return false }
        return path.strokedPath(StrokeStyle(lineWidth: margin * 2)).contains(point)
    }

    /// A point in this view's coordinates as the outline is drawn: top-left, whichever way
    /// AppKit has this view's axis.
    private func topLeft(_ local: CGPoint) -> CGPoint {
        isFlipped ? local : CGPoint(x: local.x, y: bounds.minY + (bounds.maxY - local.y))
    }

    /// Whether a point in window coordinates lies on the island, or within `margin` of it.
    /// Pure geometry: nothing here asks SwiftUI anything, so it is safe to call from any
    /// callback at any moment.
    func islandContains(windowPoint: NSPoint, margin: CGFloat = 0, includingBubble: Bool = true) -> Bool {
        guard let path = islandPath(includingBubble: includingBubble) else { return false }
        return Self.contains(path, topLeft(convert(windowPoint, from: nil)), margin: margin)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let path = islandPath() else { return nil }
        guard Self.contains(path, topLeft(convert(point, from: superview)), margin: 0) else { return nil }
        return super.hitTest(point)
    }
}

/// The island's press-in: whether a press on its body is told to the centre as one.
enum IslandPress {
    /// Only while the island is collapsed, which is the only time the press-in is drawn
    /// (`IslandBodyView`'s `pressed` asks for a layout that is not expanded). The pressed island
    /// is published, and every click inside an open panel — on the rail, the switcher, a slider,
    /// the scrubber — set it and cleared it again: the whole island drawn twice for a change
    /// nothing drew. The window's pass-through does not need it while the panel is open: a
    /// button held down there is a press that began on the island (`NotchPanel.Hold`), and with
    /// no button down the press has been cleared before it is asked about. Pure.
    static func publishes(expanded: Bool) -> Bool {
        !expanded
    }
}

/// The hit test's memory: the last outline built with the bubble and the last built without,
/// each with the layout and bounds it was built from.
///
/// Inside the canvas every move of the pointer asks for the outline two or three times — on
/// the body alone, with the bubble, and with the margin on the way out — and each of those
/// built the shape again from its layout, curves and all, for an island that had not
/// changed. One entry per way of asking, because both ways are asked on the same move and a
/// single entry would be thrown out by each in turn. The outline is made from the key and
/// nothing else, so an equal key is the same path, and an entry can never be stale.
///
/// Nothing here knows about views or windows, so the rule is tested on its own.
struct OutlineCache {
    /// What an outline is built from, and all of it.
    struct Key: Equatable {
        var layout: IslandLayout
        var bounds: CGRect
        var includingBubble: Bool
    }

    private var withBubble: (key: Key, path: Path)?
    private var bodyOnly: (key: Key, path: Path)?

    /// Whether an entry built for `kept` answers a request for `asked`: only when they are the
    /// same key. Nil, nothing built yet, answers nothing.
    static func answers(_ kept: Key?, _ asked: Key) -> Bool {
        kept == asked
    }

    /// The outline for `key`: the one kept, when it was built from the same key, and
    /// otherwise the one `build` makes now, which is kept in its place.
    mutating func outline(for key: Key, build: (Key) -> Path) -> Path {
        let kept = key.includingBubble ? withBubble : bodyOnly
        if let kept, Self.answers(kept.key, key) { return kept.path }
        let path = build(key)
        if key.includingBubble {
            withBubble = (key: key, path: path)
        } else {
            bodyOnly = (key: key, path: path)
        }
        return path
    }
}
