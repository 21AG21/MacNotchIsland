import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Holds the AppKit view the share sheet hangs off. A plain reference so writing to it
/// during a SwiftUI update never invalidates the view tree.
final class ShelfShareAnchor {
    weak var view: NSView?
}

/// Zero-cost AppKit anchor sitting behind the strip; the share picker needs a real view.
struct ShelfAnchorView: NSViewRepresentable {
    let anchor: ShelfShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// Horizontal strip of shelf items with thumbnails. Click to select (⌘ toggles, ⇧ extends),
/// right-click for the actions, drag items out to any app.
struct ShelfStripView: View {
    /// The least the strip will take: a tile and the air around it. In a section it takes the
    /// whole body instead, so the drop zone is the whole of what the pointer sees as the shelf.
    static var stripHeight: CGFloat { ShelfItemView.height + tilePadding * 2 }
    /// Air above and below the tiles: what the selection ring needs, and no more.
    static let tilePadding: CGFloat = 3

    var isDropTarget: Bool

    @ObservedObject private var shelf = ShelfStore.shared
    @State private var selection: Set<URL> = []
    @State private var selectionAnchor: URL? = nil
    @State private var shareAnchor = ShelfShareAnchor()

    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            header
            strip
        }
        .onChange(of: shelf.items) { _, current in
            let live = Set(current.map(\.url))
            selection = selection.intersection(live)
            if let anchor = selectionAnchor, !live.contains(anchor) { selectionAnchor = nil }
        }
    }

    /// The AppKit view the share picker hangs off; ImageRenderer cannot draw one, so the
    /// gallery goes without.
    @ViewBuilder
    private var anchorView: some View {
        if RenderMode.isGallery {
            Color.clear
        } else {
            ShelfAnchorView(anchor: shareAnchor).allowsHitTesting(false)
        }
    }

    // MARK: - Header

    private var headerTitle: String {
        if !selection.isEmpty { return "\(selection.count) selected" }
        // Only where the well cannot say it itself. An empty shelf puts "Drop to add" in the
        // middle of the lit well, under a tray the size of a thumbnail and right where the
        // file is going; the header saying the same thing on the line above is one sentence
        // twice. With tiles in the well there is no room for it there, so it comes up here —
        // in the same words, which is the point: it is the same moment.
        if isDropTarget, !shelf.items.isEmpty { return "Drop to add" }
        guard !shelf.items.isEmpty else { return "Shelf" }
        // The strip scrolls, so say how much there is to scroll to.
        return "Shelf · \(shelf.items.count) \(shelf.items.count == 1 ? "item" : "items")"
    }

    /// The same header every other section uses, so the shelf's title sits on the same line
    /// as Windows', Today's and the rest.
    private var header: some View {
        SectionHeader(headerTitle) {
            if !shelf.items.isEmpty {
                if !selection.isEmpty {
                    PillButton(title: "Open") { shelf.open(orderedSelection) }
                }
                PillButton(title: "AirDrop", symbol: "dot.radiowaves.right") {
                    shelf.airDrop(orderedSelection.isEmpty ? shelf.urls : orderedSelection)
                }
                // With a selection the destructive pill takes only that: emptying the whole
                // shelf when the user has picked out two files is not what they asked for.
                if selection.isEmpty {
                    PillButton(title: "Clear", tint: .white.opacity(0.85)) { shelf.clear() }
                } else {
                    PillButton(title: "Remove", tint: .white.opacity(0.85)) {
                        let going = orderedSelection
                        selection.removeAll()
                        selectionAnchor = nil
                        shelf.remove(going)
                    }
                }
            }
        }
    }

    // MARK: - Strip

    private var strip: some View {
        ZStack {
            // The drop zone is drawn only while something is being dragged; at rest the tiles
            // sit on the panel like everything else.
            //
            // Tinted and solid, the way the system marks a destination that will take what you
            // are holding — a Finder window's edge, a Mail compose sheet, a Stage Manager
            // tile. A grey dashed rectangle marks one nowhere in macOS; it is the drawing
            // convention of a web page, and it was the least Apple-made thing in the app.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(isDropTarget ? 0.18 : 0))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.9 : 0), lineWidth: 2)
            if shelf.items.isEmpty {
                emptyState
            } else {
                // The tiles start under the header, the way the window tiles do; the rest of
                // the strip stays theirs to be dropped into.
                items.frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: Self.stripHeight)
        .background(anchorView)
        .animation(IslandMotion.hover, value: isDropTarget)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: isDropTarget ? "tray.and.arrow.down.fill" : "tray")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(isDropTarget ? 0.9 : 0.3))
            Text(isDropTarget ? "Drop to add" : "Your shelf is empty")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            if !isDropTarget {
                // "Onto the island", the way the tour and every other line in the app say it.
                // The notch is the hole in the screen; the island is the thing you drop on.
                Text("Drag anything onto the island and it waits here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var items: some View {
        IslandScrollStrip(axis: .horizontal) {
            HStack(spacing: 12) {
                ForEach(shelf.items) { item in
                    ShelfItemView(item: item,
                                  isSelected: selection.contains(item.url),
                                  anchor: shareAnchor,
                                  targets: { targets(for: item.url) },
                                  onSelect: { click(item.url) })
                        .transition(IslandMotion.pop(scale: 0.6))
                }
            }
            // No inset of its own: the first tile lines up with the section's header and with
            // every other section's content.
            .padding(.vertical, Self.tilePadding)
            // A dropped file pops into place and the rest shuffle over; a removed one shrinks away.
            .animation(IslandMotion.content, value: shelf.items)
        }
    }

    // MARK: - Selection

    /// Selected URLs in shelf order.
    private var orderedSelection: [URL] {
        shelf.items.map(\.url).filter { selection.contains($0) }
    }

    /// Right-click acts on the whole selection when the clicked item is part of it.
    private func targets(for url: URL) -> [URL] {
        selection.contains(url) ? orderedSelection : [url]
    }

    private func click(_ url: URL) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
            selectionAnchor = url
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor,
                  let start = shelf.items.firstIndex(where: { $0.url == anchor }),
                  let end = shelf.items.firstIndex(where: { $0.url == url }) {
            let range = start <= end ? start...end : end...start
            for index in range { selection.insert(shelf.items[index].url) }
        } else if selection == [url] {
            selection.removeAll()
            selectionAnchor = nil
        } else {
            selection = [url]
            selectionAnchor = url
        }
    }
}

struct ShelfItemView: View {
    let item: ShelfItem
    var isSelected: Bool
    var anchor: ShelfShareAnchor
    var targets: () -> [URL]
    var onSelect: () -> Void

    @ObservedObject private var shelf = ShelfStore.shared
    @State private var hovering = false

    private var url: URL { item.url }

    /// The width of a tile, which is the width of the picture in it.
    ///
    /// 72 pt of picture is what fills the section's body, and a shelf is for seeing what you
    /// parked: at 56 the tiles used three quarters of the room and left a band of black under
    /// them, and a screenshot was too small to tell from the next screenshot.
    ///
    /// The name goes under the middle of the picture, and the tile is no wider than the
    /// picture so that it can. A 92 pt name box over a 72 pt picture, both hung from the
    /// column's leading edge so the first tile starts where the header does, left no name
    /// under the middle of the thing it names — and by a different amount for every name,
    /// since a short one hugs the left of its box and a long one fills it.
    static let column: CGFloat = 72
    static let thumbnailSize: CGFloat = 72
    /// The same gap the window tiles put between a picture and its name.
    static let labelGap: CGFloat = 4
    /// Two lines of it, the way Finder's icon view sets a file's name. On one line, in the
    /// 72 pt the picture is wide, "Screenshot 2026-09-08.png" came out as "Scree…8.png" —
    /// which does not tell one screenshot from the next, and telling one from the next is
    /// what a shelf is for.
    static let labelLines = 2
    static let labelHeight: CGFloat = 26
    static var height: CGFloat { thumbnailSize + labelGap + labelHeight }

    var body: some View {
        VStack(spacing: Self.labelGap) {
            thumbnail
                // The left mouse on the picture belongs to AppKit: a click selects, a double
                // click opens, and a drag takes every selected file at once, which SwiftUI's
                // one-item `onDrag` cannot do. The row of buttons below stays SwiftUI's.
                .overlay {
                    if !RenderMode.isGallery {
                        ShelfDragHandle(urls: targets, onClick: onSelect, onOpen: { shelf.open(targets()) })
                    }
                }
            // Hovering swaps the name for what you would do with the file. Copy first: it is
            // the thing people want most from a shelf and it was hidden in a menu.
            ZStack {
                Text(url.lastPathComponent)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(Self.labelLines)
                    .truncationMode(.middle)
                    .opacity(hovering ? 0 : 1)
                if hovering { actions }
            }
            .frame(width: Self.column, height: Self.labelHeight)
        }
        .frame(width: Self.column)
        .contentShape(Rectangle())
        .help(ageText.isEmpty ? url.path : "\(url.path)\nAdded \(ageText) ago")
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { shelf.open([url]) }
        .onTapGesture { onSelect() }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("File \(url.lastPathComponent), added \(accessibilityAge)")
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityHint("Double-click to open, right-click for actions")
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: Text("Open")) { shelf.open([url]) }
    }

    /// "2h" / "3d" / "just now" — the same age used on screen, spelled out for a reading
    /// that never lands on an empty string.
    private var accessibilityAge: String {
        ageText.isEmpty ? "just now" : ageText
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = shelf.thumbnail(for: url) {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: 2)
                }
            }
        }
    }

    /// Copy, Quick Look, remove — the three things a shelf is for, under the tile.
    private var actions: some View {
        HStack(spacing: 4) {
            tileButton("doc.on.doc", "Copy") { shelf.copyToPasteboard(targets()) }
            tileButton("eye", "Quick Look") { ShelfQuickLook.shared.show(targets()) }
            tileButton("xmark", "Remove") { shelf.remove(targets()) }
        }
        .transition(.opacity)
    }

    private func tileButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.14))
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 18, height: 18)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open") { shelf.open(targets()) }
        Button("Quick Look") { ShelfQuickLook.shared.show(targets()) }
        Button("Reveal in Finder") { shelf.revealInFinder(targets()) }
        Divider()
        Button("AirDrop") { shelf.airDrop(targets()) }
        Button("Share…") {
            let view = anchor.view
            shelf.share(targets(), from: view, rect: view?.bounds ?? .zero)
        }
        Button(copyTitle) { shelf.copyToPasteboard(targets()) }
        Divider()
        // Named for what it does, beside the one that does the other thing: a bare "Remove"
        // next to "Move to Trash" reads as a choice between two kinds of deleting.
        Button("Remove from Shelf") { shelf.remove(targets()) }
        Button("Move to Trash") { shelf.moveToTrash(targets()) }
    }

    /// What "Copy" will put on the pasteboard, so the menu says what it does.
    private var copyTitle: String {
        let files = targets()
        guard files.count == 1 else { return "Copy \(files.count) Files" }
        switch ShelfStore.copyKind(of: files[0]) {
        case .text: return "Copy Text"
        case .image: return "Copy Image"
        case .file: return "Copy File"
        }
    }

    /// "2h" / "3d" once an item has been sitting on the shelf for at least an hour.
    private var ageText: String {
        let seconds = Date().timeIntervalSince(item.addedAt)
        guard seconds >= 3600 else { return "" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
