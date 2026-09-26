import SwiftUI

/// The panel's find field: a magnifying glass in a section's header that opens into a search
/// box, and the thing the letter keys type into.
///
/// It is collapsed until there is a find to show, because a permanent search box in a header
/// that is 12 pt tall is a lot of furniture for something used now and then — and because the
/// way in is meant to be typing, the way it is in Finder. Clicking the glass is the other way
/// in, for the people who look for one.
struct FindField: View {
    /// How many rows the query is showing, drawn small on the trailing edge. Nil hides it.
    var matches: Int?
    /// Return, on whatever the section thinks is first.
    var onSubmit: () -> Void = {}
    /// What the row at an index of the matches is called, for VoiceOver to say as the arrows
    /// reach it. The centre knows only the index; the section knows what is there. Nil says
    /// only where in the matches the mark is.
    var spokenRow: (Int) -> String? = { _ in nil }

    @ObservedObject private var center = ActivityCenter.shared
    /// Watched, so a change of Reduce Motion redraws the field with the transition it asks for.
    @ObservedObject private var display = AccessibilityDisplay.shared
    /// Which island this field is drawn on, for `speaksCount`.
    @Environment(\.islandPanelID) private var panelID
    // Qualified: the island has a `FocusState` of its own, the payload of a Focus activity.
    @SwiftUI.FocusState private var focused: Bool

    /// Wide enough for a filename or a window title, and no wider than the pills beside it
    /// would allow.
    static let width: CGFloat = 168
    static let height: CGFloat = 22
    /// The box the clear button's glyph is laid out in.
    static let clearGlyph: CGFloat = 12

    var body: some View {
        Group {
            if center.findQuery == nil { glass } else { field }
        }
        .animation(IslandMotion.content, value: center.findQuery == nil)
    }

    /// The way in for a pointer: the same glyph the field wears, on its own.
    private var glass: some View {
        Button(action: { ActivityCenter.shared.beginFind() }) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: Self.height, height: Self.height)
                // The same fill the pills beside it wear, so the glass reads as a control
                // on that line rather than as a decoration printed on the black.
                .background(Circle().fill(Color.white.opacity(0.12)))
                // Drawn at the line's 22 pt, and taking its click in 24 like the pills.
                .hitOutset(drawn: Self.height)
        }
        .buttonStyle(IslandButtonStyle())
        .help("Find — or just start typing")
        .accessibilityLabel("Find")
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityHidden(true)
            text
            if let matches, !(center.findQuery ?? "").isEmpty {
                Text("\(matches)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(matches == 0 ? 0.3 : 0.45))
                    .accessibilityLabel(Self.matchCount(matches))
            }
            Button(action: { ActivityCenter.shared.endFind() }) {
                // An 11 pt glyph was the whole of what took the click, the smallest target in
                // the app. It is laid out in the 12 it is drawn in and answers in 24 around it,
                // spending the gap before the count and most of the field's end padding.
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: Self.clearGlyph, height: Self.clearGlyph)
                    .hitOutset(drawn: Self.clearGlyph)
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("Stop finding")
        }
        .padding(.horizontal, 9)
        .frame(width: Self.width, height: Self.height)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .transition(display.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
        // The count beside the field changes with every letter, and a screen reader is in the
        // field, not on the count: what it comes to is said as the field opens and as it
        // changes. At medium, after the letter VoiceOver echoes as it is typed. Said rather than
        // made the field's value, which is the text in it — the value VoiceOver reads back, and
        // moves through letter by letter.
        .onChange(of: matches, initial: true) { _, now in
            // One island says it. The find is open on every display that shows the section,
            // and each draws a field of its own, so the count was heard once a display; the
            // field whose window holds the keyboard is the one being typed into. The app is
            // optional here: the gallery draws the field in a process with no application.
            guard Self.speaksCount(panelID: panelID, keyPanelID: (NSApp?.keyWindow as? NotchPanel)?.panelID),
                  let words = Self.countAnnouncement(matches: now, query: ActivityCenter.shared.findQuery) else { return }
            IslandAccessibility.announce(words, high: false)
        }
    }

    /// Whether the field on island `panelID` is the one to say the count: the one whose window
    /// holds the keyboard, and none while no island does. Pure, so it is tested.
    static func speaksCount(panelID: String, keyPanelID: String?) -> Bool {
        keyPanelID == panelID
    }

    /// "No matches", "1 match", "12 matches". Pure, so it is tested.
    static func matchCount(_ count: Int) -> String {
        switch count {
        case ...0: return "No matches"
        case 1: return "1 match"
        default: return "\(count) matches"
        }
    }

    /// What is said when the count changes: the count, while something has been typed for it
    /// to be a count of. Nothing with the field empty, where the count is not drawn either.
    /// Pure, so it is tested.
    static func countAnnouncement(matches: Int?, query: String?) -> String? {
        guard let matches, let query, !query.isEmpty else { return nil }
        return matchCount(matches)
    }

    /// What is said as the arrows move the mark: the row's name where the section gave one, and
    /// where it is in the matches — "Report.pdf, 2 of 5". The mark is a ring on a row, which
    /// said nothing at all to somebody who cannot see it. Pure, so it is tested.
    static func moveAnnouncement(row: String?, index: Int, count: Int) -> String {
        let place = "\(index + 1) of \(count)"
        guard let row, !row.isEmpty else { return place }
        return "\(row), \(place)"
    }

    /// Moves the mark, and says where it went.
    private func move(by delta: Int) {
        let count = matches ?? 0
        let centre = ActivityCenter.shared
        centre.moveFind(by: delta, count: count)
        guard let index = centre.findTarget(of: count) else { return }
        IslandAccessibility.announce(Self.moveAnnouncement(row: spokenRow(index), index: index, count: count))
    }

    /// Puts the caret after the text in whichever field editor has the keyboard. A hop
    /// later, because focus is applied after this change is observed.
    private static func moveCaretToEnd() {
        DispatchQueue.main.async {
            guard let editor = NSApp?.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
    }

    @ViewBuilder
    private var text: some View {
        if RenderMode.isGallery {
            // The real field takes the width and pushes the glyph to the leading edge; the
            // stand-in has to do the same or the gallery lies about it.
            Text(center.findQuery?.isEmpty == false ? (center.findQuery ?? "") : "Find")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(center.findQuery?.isEmpty == false ? 1 : 0.35))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Find", text: Binding(
                get: { ActivityCenter.shared.findQuery ?? "" },
                set: { ActivityCenter.shared.updateFind($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .focused($focused)
            .onSubmit(onSubmit)
            // The rest of the way Spotlight works: type, walk the matches, press Return. The
            // field has the keyboard while a find is up, so these belong to it rather than to
            // the panel's own arrow keys, which are handed back the moment a find begins.
            .onKeyPress(.upArrow) {
                move(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                move(by: 1)
                return .handled
            }
            // The letters that opened this were claimed from the system, not typed into a
            // field; the caret has to be put where they are going, and put there again if the
            // field is reused for the next find.
            .onAppear { focused = true }
            .onChange(of: center.findQuery == nil) { _, gone in if !gone { focused = true } }
            // Focus lands with the field's text selected, the way it does in every text
            // field on the Mac — and the text is the letter that opened the find, so the
            // next letter typed replaced it: "safari" found "afari". The caret goes to the end.
            .onChange(of: focused) { _, now in if now { Self.moveCaretToEnd() } }
            .accessibilityLabel("Find")
        }
    }
}
