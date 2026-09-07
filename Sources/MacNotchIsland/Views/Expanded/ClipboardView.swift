import AppKit
import SwiftUI

/// Clipboard history for the Home panel's "Clipboard" tab: newest copy first, click a row
/// to put it back on the pasteboard, hover for pin / copy / remove.
struct ClipboardView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @State private var hoveredID: UUID? = nil

    var body: some View {
        Group {
            if store.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.items) { item in
                    ClipboardRowView(item: item, isHovered: hoveredID == item.id)
                        .onHover { hovering in
                            if hovering {
                                hoveredID = item.id
                            } else if hoveredID == item.id {
                                hoveredID = nil
                            }
                        }
                    if item.id != store.items.last?.id {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.leading, 34)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityHidden(true)
            Text("Nothing copied yet")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                glyph
                Text(item.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { copyBack() }
        .animation(IslandMotion.quick, value: isHovered)
    }

    @ViewBuilder
    private var glyph: some View {
        if item.kind == .image, let thumbnail = store.thumbnail(for: item) {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 18, height: 18)
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
                Text(item.age())
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: 76, alignment: .trailing)
        // The row's own accessibility label already states the age (and the pin/copy/delete
        // actions above cover the hover buttons), so this half of the tree stays silent
        // rather than doubling up on what VoiceOver just read.
        .accessibilityHidden(true)
    }

    private func copyBack() {
        store.copy(item: item)
        let activity = IslandActivity(id: "clipboard-copied",
                                      kind: .custom,
                                      content: .custom(CustomActivity(title: "Copied",
                                                                      symbol: "doc.on.clipboard",
                                                                      trailingText: "Copied")),
                                      priority: 80)
        ActivityCenter.shared.showAlert(activity, duration: 1.0, haptic: false)
        // Alerts linger while the pointer is on the island, and the pointer is by definition
        // still here after a click, so retire this one ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            if ActivityCenter.shared.alert?.id == activity.id { ActivityCenter.shared.dismissAlert() }
        }
    }
}

/// Small hairline-free glyph button used only inside a clipboard row.
private struct ClipboardRowButton: View {
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
    }
}
