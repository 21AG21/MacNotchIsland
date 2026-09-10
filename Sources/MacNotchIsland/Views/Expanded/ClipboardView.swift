import AppKit
import SwiftUI

/// Clipboard history for the Home panel's "Clipboard" tab: newest copy first, click a row
/// to put it back on the pasteboard, hover for pin / copy / remove.
struct ClipboardView: View {
    /// Text the list is filtered by; empty shows everything.
    var query: String = ""
    /// The row the find is pointing at, which Return would pick. Nil when nobody is finding.
    var found: UUID? = nil
    @ObservedObject private var store = ClipboardStore.shared
    @State private var hoveredID: UUID? = nil

    var body: some View {
        Group {
            if store.items.isEmpty {
                emptyState
            } else if ordered.isEmpty {
                SectionEmptyState(symbol: "magnifyingglass", title: "No matches")
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Files can be moved or deleted while the panel is shut and nothing says so, so the
        // question is put to the disk once, here, rather than by every row as it draws.
        .onAppear { store.refreshMissingFiles() }
    }

    private var list: some View {
        IslandScrollStrip(axis: .vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(ordered) { item in
                    ClipboardRowView(item: item, isHovered: hoveredID == item.id || found == item.id)
                        .onHover { hovering in
                            if hovering {
                                hoveredID = item.id
                            } else if hoveredID == item.id {
                                hoveredID = nil
                            }
                        }
                    if item.id != ordered.last?.id {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.leading, ClipboardRowView.textInset)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var ordered: [ClipboardItem] { Self.ordered(store.items, query: query) }

    /// Pinned items first, then the rest, newest first; only what matches the search. Static
    /// so the header can count the matches and Return can pick the first of them without
    /// working the rule out a second time.
    static func ordered(_ items: [ClipboardItem], query: String?) -> [ClipboardItem] {
        let all = items.filter(\.pinned) + items.filter { !$0.pinned }
        // The app it came from is searched too: "the link from Safari" is how people
        // remember a copy, far more often than by the words in it.
        return all.filter { PanelFind.matches([$0.preview, $0.app ?? ""], query: query) }
    }

    private var emptyState: some View {
        SectionEmptyState(symbol: "doc.on.clipboard", title: "No copies yet",
                          subtitle: "Anything you copy shows up here, the last \(Int(Preferences.shared.clipboardLimit)) items.")
    }
}

/// Sentence-case name for a clipboard entry's kind, used only for VoiceOver.
private extension ClipboardItem.Kind {
    var accessibilityName: String {
        switch self {
        case .text: return "text"
        case .url: return "link"
        case .file: return "file"
        case .image: return "image"
        }
    }
}

/// One history row: type glyph, first line, and either the age or the hover controls.
private struct ClipboardRowView: View {
    let item: ClipboardItem
    var isHovered: Bool

    @ObservedObject private var store = ClipboardStore.shared

    /// The row's leading mark stands on the section's column, like every other section's
    /// content, rather than six points inside it. The hover highlight is the column exactly:
    /// the section clips at its edges, so a highlight that bled past them would be cut square.
    static let glyphBox: CGFloat = 16
    static let glyphGap: CGFloat = 10
    /// Where a row's text starts, and so where the hairline between two rows starts.
    static var textInset: CGFloat { glyphBox + glyphGap }

    /// A copied file that has since been moved or deleted, so the list never offers a dead
    /// reference silently. Read from the store's last sweep rather than from the disk: a row
    /// is redrawn on every hover and every scroll, and asking here meant a `stat` per file
    /// per redraw on the thread that draws.
    private var missing: Bool { store.filesAreGone(item) }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: Self.glyphGap) {
                glyph
                Text(item.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(missing ? 0.45 : 1))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if missing {
                    Text("no longer on disk")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Copied \(item.kind.accessibilityName): \(item.preview), \(item.age())")
            .accessibilityHint("Click to copy again")
            .accessibilityAction { copyBack() }
            .accessibilityAction(named: Text(item.pinned ? "Unpin" : "Pin")) { store.togglePin(item: item) }
            .accessibilityAction(named: Text("Delete")) { store.remove(item: item) }
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { copyBack() }
        .modifier(DragOut(item: item))
        .animation(IslandMotion.hover, value: isHovered)
    }

    @ViewBuilder
    private var glyph: some View {
        if item.kind == .image, let thumbnail = store.thumbnail(for: item) {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.glyphBox, height: Self.glyphBox)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: Self.glyphBox, height: Self.glyphBox, alignment: .leading)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 2) {
            if isHovered {
                ClipboardRowButton(symbol: item.pinned ? "pin.fill" : "pin") { store.togglePin(item: item) }
                    .accessibilityLabel(item.pinned ? "Unpin" : "Pin")
                ClipboardRowButton(symbol: "doc.on.doc") { copyBack() }
                    .accessibilityLabel("Copy")
                ClipboardRowButton(symbol: "xmark") { store.remove(item: item) }
                    .accessibilityLabel("Delete")
            } else {
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                // Where it came from over how long ago, both quiet: a list of fifty snippets
                // is scanned by memory — "the link from Safari" — far more often than it is
                // read word by word.
                VStack(alignment: .trailing, spacing: 0) {
                    if let app = item.app, !app.isEmpty {
                        Text(app)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.32))
                            .lineLimit(1)
                    }
                    Text(item.age())
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(width: 76, alignment: .trailing)
        // The row's own accessibility label already states the age (and the pin/copy/delete
        // actions above cover the hover buttons), so this half of the tree stays silent
        // rather than doubling up on what VoiceOver just read.
        .accessibilityHidden(true)
    }

    private func copyBack() { store.pick(item: item) }
}

/// Small hairline-free glyph button used only inside a clipboard row.
/// A row you can drag straight into a document, a message or a folder — the other half of
/// clicking one, which puts it back on the pasteboard. Only rows with something behind them
/// get the gesture, so a drag never starts and then carries nothing.
private struct DragOut: ViewModifier {
    let item: ClipboardItem

    @ViewBuilder
    func body(content: Content) -> some View {
        if item.canDrag {
            content
                .onDrag { item.dragProvider() ?? NSItemProvider() }
                .help("Click to copy it again, or drag it straight into a document.")
        } else {
            content
        }
    }
}

private struct ClipboardRowButton: View {
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
    }
}
