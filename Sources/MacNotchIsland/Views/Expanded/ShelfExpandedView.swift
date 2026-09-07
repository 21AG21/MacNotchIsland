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
            ShelfStripView(isDropTarget: isDropTarget)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
    }
}

/// Horizontal strip of shelf items with thumbnails. Drag items out to any app.
struct ShelfStripView: View {
    var isDropTarget: Bool
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isDropTarget ? "Drop to keep here" : "Shelf")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(isDropTarget ? 1 : 0.6))
                Spacer()
                if !shelf.items.isEmpty {
                    Button(action: { shelf.clear() }) {
                        Text("Clear").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(IslandButtonStyle())
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: isDropTarget ? [6, 4] : []))
                    .foregroundStyle(.white.opacity(isDropTarget ? 0.6 : 0.14))
                if shelf.items.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(isDropTarget ? 0.9 : 0.4))
                        Text(isDropTarget ? "Release to add" : "Drag files onto the notch")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items, id: \.self) { url in
                                ShelfItemView(url: url)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .animation(IslandMotion.quick, value: isDropTarget)
        }
    }
}

struct ShelfItemView: View {
    let url: URL
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
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
                if hovering {
                    Button(action: { shelf.remove(url) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white, .black.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                }
            }
            Text(url.lastPathComponent)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: 56)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}
