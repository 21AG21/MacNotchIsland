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

    @ObservedObject private var center = ActivityCenter.shared
    // Qualified: the island has a `FocusState` of its own, the payload of a Focus activity.
    @SwiftUI.FocusState private var focused: Bool

    /// Wide enough for a filename or a window title, and no wider than the pills beside it
    /// would allow.
    static let width: CGFloat = 168
    static let height: CGFloat = 22

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
                .contentShape(Circle())
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
                    .accessibilityLabel(matches == 1 ? "1 match" : "\(matches) matches")
            }
            Button(action: { ActivityCenter.shared.endFind() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .contentShape(Circle())
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("Stop finding")
        }
        .padding(.horizontal, 9)
        .frame(width: Self.width, height: Self.height)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
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
                ActivityCenter.shared.moveFind(by: -1, count: matches ?? 0)
                return .handled
            }
            .onKeyPress(.downArrow) {
                ActivityCenter.shared.moveFind(by: 1, count: matches ?? 0)
                return .handled
            }
            // The letters that opened this were claimed from the system, not typed into a
            // field; the caret has to be put where they are going, and put there again if the
            // field is reused for the next find.
            .onAppear { focused = true }
            .onChange(of: center.findQuery == nil) { _, gone in if !gone { focused = true } }
            .accessibilityLabel("Find")
        }
    }
}
