import SwiftUI

/// The Home panel's "Notifications" tab: what came past on a banner while you were not
/// looking, newest first.
///
/// The Mac has never had a notification history, and this is the only part of the island that
/// still knows about a banner an hour after it went. It is drawn as the clipboard's list is
/// drawn — same column, same row furniture, same hairline — because the two answer the same
/// question in the same shape ("what was that thing from earlier?"), and two lists in one
/// panel that look like two different apps is worse than either.
struct NotificationsSectionView: View {
    @ObservedObject private var inbox = NotificationInbox.shared
    /// The find is the panel's, not this view's: it is opened by typing on the section as
    /// much as by clicking the glass, and it has to survive the row that is redrawn under it.
    @ObservedObject private var center = ActivityCenter.shared

    private var matches: [NotificationInbox.Entry] { Self.ordered(inbox.entries, query: center.findQuery) }

    /// The list as it is drawn: collapsed into a block per app, the app that spoke most
    /// recently first, and only what answers the find.
    ///
    /// Narrowed before it is grouped rather than after, so that a find rearranges the list the
    /// way the list itself is arranged — the app with the newest match at the top of it,
    /// rather than the app with the newest notification you are not looking for.
    static func ordered(_ entries: [NotificationInbox.Entry], query: String?) -> [NotificationInbox.Entry] {
        let kept = entries.filter { NotificationInbox.matches($0, query: query) }
        return NotificationInbox.grouped(kept).flatMap(\.entries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            SectionHeader(inbox.entries.isEmpty ? "Notifications" : "Notifications · \(inbox.entries.count)") {
                // The glass appears with the first notification; a find already under way
                // keeps its field whatever the list does, so an entry ageing out from under it
                // never takes the caret away mid-word.
                if !inbox.entries.isEmpty || center.findQuery != nil {
                    FindField(matches: matches.count)
                }
                if !inbox.entries.isEmpty {
                    PillButton(title: "Clear", tint: .white.opacity(0.85)) { inbox.clear() }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        if inbox.entries.isEmpty {
            SectionEmptyState(symbol: "bell", title: "Nothing yet",
                              subtitle: "Whatever comes past on a banner is kept here for three days. "
                                      + "Reading them needs Accessibility, which is granted in Settings.")
        } else if matches.isEmpty {
            SectionEmptyState(symbol: "magnifyingglass", title: "No matches")
        } else {
            list
        }
    }

    private var list: some View {
        // Worked out once for the whole list rather than once per row: grouping two hundred
        // notifications is not the sort of thing to do forty times on the way down a column.
        let rows = matches
        // The row the arrows are on. Nothing happens to it on Return — a notification that has
        // been and gone has nowhere to be opened — but walking the matches has to show where
        // you are, so it is marked the way a row under the pointer is.
        let found = center.findTarget(of: rows.count).map { rows[$0].id }
        return IslandScrollStrip(axis: .vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { entry in
                    NotificationRowView(entry: entry, isFound: found == entry.id)
                    if entry.id != rows.last?.id {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.leading, NotificationRowView.textInset)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

/// One row: the app that sent it, what it said, and how long ago — with the one thing that can
/// still be done about a notification that has already happened, which is to forget it.
private struct NotificationRowView: View {
    let entry: NotificationInbox.Entry
    /// The row the find's mark is on, drawn the way a hovered row is so that walking the
    /// matches with the arrows shows where you are.
    var isFound: Bool

    @State private var hovering = false

    /// The clipboard's own column, to the point: a row here and a row there have their marks
    /// on the same line and their text on the same one.
    static let glyphBox: CGFloat = 16
    static let glyphGap: CGFloat = 10
    /// Where a row's text starts, and so where the hairline between two rows starts.
    static var textInset: CGFloat { glyphBox + glyphGap }
    /// Taller than a clipboard row, because a notification is a title and then what it said,
    /// and a copied line is one line. Three of these and the beginning of a fourth stand in
    /// the section's body, which is what tells somebody the list goes on.
    static let rowHeight: CGFloat = 34
    /// Room for "just now" shortened, or for the button that replaces it.
    static let trailingWidth: CGFloat = 34

    private var isMarked: Bool { hovering || isFound }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: Self.glyphGap) {
                glyph
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Quiet, and first: "the thing from the bank" is how a notification is
                        // remembered, so the app is what the eye runs down the column for.
                        Text(entry.appName)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.32))
                            .lineLimit(1)
                        Text(headline)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(entry.isThin ? 0.55 : 1))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityAction(named: Text("Forget")) { NotificationInbox.shared.remove(id: entry.id) }
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(isMarked ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in hovering = inside }
        .animation(IslandMotion.hover, value: isMarked)
    }

    @ViewBuilder
    private var glyph: some View {
        Image(systemName: entry.isThin ? "questionmark.circle" : "bell.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: Self.glyphBox, height: Self.glyphBox, alignment: .leading)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 2) {
            if hovering {
                NotificationRowButton(symbol: "xmark") { NotificationInbox.shared.remove(id: entry.id) }
                    .accessibilityLabel("Forget")
            } else {
                Text(age)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: Self.trailingWidth, alignment: .trailing)
        // The row's own label already states the app, the words and the age, and the action
        // above covers the button, so this half of the tree stays silent rather than doubling
        // up on what VoiceOver just read.
        .accessibilityHidden(true)
    }

    /// The two lines a row is drawn from: what it leads with, and the quieter one under it.
    ///
    /// Nearly always the title and then the words, but a banner is only ever whatever could be
    /// read off it. One with words and no title of its own leads with the words rather than
    /// hanging them under an empty line; one that could not be read at all says so, because a
    /// row that knows the app and the moment is still worth having and a blank one is not.
    private var lines: (headline: String, detail: String?) {
        guard !entry.isThin else {
            return (headline: "Something arrived", detail: "The words could not be read.")
        }
        var rest = [entry.subtitle, entry.body].compactMap { $0 }
        var lead = entry.title
        if lead.isEmpty, !rest.isEmpty { lead = rest.removeFirst() }
        guard !rest.isEmpty else { return (headline: lead, detail: nil) }
        // The watcher joins everything else it found in a banner with newlines, and a newline
        // in a line one line tall costs the rest of what was said.
        let said = rest.joined(separator: " — ").replacingOccurrences(of: "\n", with: " ")
        return (headline: lead, detail: said)
    }

    private var headline: String { lines.headline }
    private var detail: String? { lines.detail }

    /// Compact relative age — "now", "4m", "3h", "2d" — the shorthand the clipboard's rows
    /// use, so the two columns of times read as one thing rather than as two conventions.
    private var age: String {
        let seconds = max(0, Date().timeIntervalSince(entry.date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// What VoiceOver reads. Spelled out rather than clipped: the row truncates because it is
    /// 34 points tall, which is no reason for somebody listening to be told less.
    private var spoken: String {
        [entry.appName, headline, detail ?? "", age].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Small hairline-free glyph button used only inside a notification row.
private struct NotificationRowButton: View {
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
