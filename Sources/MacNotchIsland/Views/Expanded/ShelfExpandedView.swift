import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Full-width shelf shown while a file is being dragged over the island.
struct ShelfExpandedView: View {
    let geometry: NotchGeometry
    let layout: IslandLayout
    var isDropTarget: Bool

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 10)
            ShelfStripView(isDropTarget: isDropTarget, wide: true)
                .padding(.horizontal, IslandInsets.horizontal)
                .padding(.bottom, 14)
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
    }
}

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
    var isDropTarget: Bool
    /// The full-width shelf panel. Home passes the default and gets the narrow column.
    var wide: Bool = false

    @ObservedObject private var shelf = ShelfStore.shared
    @State private var selection: Set<URL> = []
    @State private var selectionAnchor: URL? = nil
    @State private var shareAnchor = ShelfShareAnchor()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            strip
        }
        .onChange(of: shelf.items) { _, current in
            let live = Set(current.map(\.url))
            selection = selection.intersection(live)
            if let anchor = selectionAnchor, !live.contains(anchor) { selectionAnchor = nil }
        }
    }

    // MARK: - Header

    private var headerTitle: String {
        if !selection.isEmpty { return "\(selection.count) selected" }
        return isDropTarget ? "Drop to keep here" : "Shelf"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isDropTarget ? 1 : 0.6))
                .lineLimit(1)
            Spacer(minLength: 0)
            if !shelf.items.isEmpty {
                // The narrow Home column only has room for two pills; Open lives on the
                // double-click and in the context menu there.
                if wide && !selection.isEmpty {
                    PillButton(title: "Open") { shelf.open(orderedSelection) }
                }
                PillButton(title: "AirDrop", symbol: wide ? "dot.radiowaves.right" : nil) {
                    shelf.airDrop(orderedSelection.isEmpty ? shelf.urls : orderedSelection)
                }
                PillButton(title: "Clear", tint: .white.opacity(0.85)) {
                    selection.removeAll()
                    selectionAnchor = nil
                    shelf.clear()
                }
            }
        }
        .frame(height: 29)
    }

    // MARK: - Strip

    private var strip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: isDropTarget ? [6, 4] : []))
                .foregroundStyle(.white.opacity(isDropTarget ? 0.6 : 0.14))
            if shelf.items.isEmpty {
                emptyState
            } else {
                items
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .background(ShelfAnchorView(anchor: shareAnchor).allowsHitTesting(false))
        .animation(IslandMotion.quick, value: isDropTarget)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(isDropTarget ? 0.9 : 0.4))
            Text(isDropTarget ? "Release to add" : "Drag files onto the notch")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var items: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(shelf.items) { item in
                    ShelfItemView(item: item,
                                  isSelected: selection.contains(item.url),
                                  anchor: shareAnchor,
                                  targets: { targets(for: item.url) },
                                  onSelect: { click(item.url) })
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
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

    var body: some View {
        VStack(spacing: 3) {
            thumbnail
            Text(url.lastPathComponent)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: 56)
            Text(ageText)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .frame(height: 10)
        }
        .contentShape(Rectangle())
        .help(url.path)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { shelf.open([url]) }
        .onTapGesture { onSelect() }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
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
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: 2)
                }
            }
            if hovering {
                Button(action: { shelf.remove([url]) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, .black.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(IslandButtonStyle())
                .accessibilityLabel("Remove")
                .offset(x: 6, y: -6)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open") { shelf.open(targets()) }
        Button("Reveal in Finder") { shelf.revealInFinder(targets()) }
        Divider()
        Button("AirDrop") { shelf.airDrop(targets()) }
        Button("Share…") {
            let view = anchor.view
            shelf.share(targets(), from: view, rect: view?.bounds ?? .zero)
        }
        Button("Copy") { shelf.copyToPasteboard(targets()) }
        Divider()
        Button("Remove") { shelf.remove(targets()) }
        Button("Move to Trash") { shelf.moveToTrash(targets()) }
    }

    /// "2h" / "3d" once an item has been sitting on the shelf for at least an hour.
    private var ageText: String {
        let seconds = Date().timeIntervalSince(item.addedAt)
        guard seconds >= 3600 else { return "" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
