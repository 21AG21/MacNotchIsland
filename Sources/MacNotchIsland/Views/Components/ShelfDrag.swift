import AppKit
import SwiftUI

/// The left mouse on a shelf tile: click to select, double-click to open, drag to take the
/// files somewhere.
///
/// SwiftUI's `onDrag` can only hand over one item, so a shelf of ten selected files left as
/// one file. This is a real `NSDraggingSession` instead, with one dragging item per file and
/// the icons stacked behind the one under the pointer, exactly as Finder drags a selection.
///
/// The view takes only the left mouse. `hitTest` looks at the event being dispatched and
/// steps aside for anything else, so the SwiftUI tile underneath keeps its hover, its
/// right-click menu and its share of the scroll.
struct ShelfDragHandle: NSViewRepresentable {
    /// The files this drag carries: the selection when the tile is part of it, else the tile.
    var urls: () -> [URL]
    var onClick: () -> Void
    var onOpen: () -> Void

    func makeNSView(context: Context) -> ShelfDragView {
        let view = ShelfDragView()
        view.urls = urls
        view.onClick = onClick
        view.onOpen = onOpen
        return view
    }

    func updateNSView(_ view: ShelfDragView, context: Context) {
        view.urls = urls
        view.onClick = onClick
        view.onOpen = onOpen
    }
}

final class ShelfDragView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onClick: () -> Void = {}
    var onOpen: () -> Void = {}

    /// How far the pointer travels before a click becomes a drag.
    static let dragThreshold: CGFloat = 4
    /// How far each icon behind the first is offset, so a multi-file drag reads as a pile.
    static let stackOffset: CGFloat = 6
    /// The most icons drawn in that pile; beyond this the badge does the counting.
    static let maxStacked = 4

    private var mouseDownPoint: NSPoint?
    private var dragged = false

    /// Only left-mouse events belong to this view; hover, right-click and scrolling belong to
    /// the SwiftUI tile it covers.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = mouseDownPoint else { return }
        let delta = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        guard delta > Self.dragThreshold else { return }
        dragged = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragged else { return }
        if event.clickCount >= 2 {
            onOpen()
        } else {
            onClick()
        }
    }

    private func beginDrag(with event: NSEvent) {
        let files = urls()
        guard !files.isEmpty else { return }
        let origin = convert(event.locationInWindow, from: nil)
        var items: [NSDraggingItem] = []
        for (index, url) in files.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let side = bounds.width > 0 ? min(bounds.width, bounds.height) : 56
            let offset = CGFloat(min(index, Self.maxStacked)) * Self.stackOffset
            let frame = NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset,
                               width: side, height: side)
            item.setDraggingFrame(frame, contents: index < Self.maxStacked ? icon : nil)
            items.append(item)
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = files.count > 1 ? .stack : .none
    }

    // MARK: - NSDraggingSource

    /// Always a copy: dragging a file out of the shelf must never move the original away from
    /// where it lives.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // The panel must stay while the pointer is away carrying the files.
        ActivityCenter.shared.setControlDragging(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ActivityCenter.shared.setControlDragging(false)
    }
}
