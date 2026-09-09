import SwiftUI

/// The panel's top band, the one place the island has that nothing else needs: the button that
/// closes the panel and the live activities' cards sit left of the camera cutout, the Home
/// sections right of it, and the cutout itself is the divider. Every view the panel can show is
/// one click away here.
///
/// On a screen with no cutout there is nothing to divide the two around, so they run together
/// as one row from the leading edge with a step of space between them.
struct SwitcherBand: View {
    let geometry: NotchGeometry
    let current: IslandView?
    @EnvironmentObject private var center: ActivityCenter
    /// The slot the pointer is on, so the band can name it. Nothing else depends on it.
    @State private var hovered: IslandView?
    /// The slot a drag is resting on, and the switch it will make if it stays.
    @State private var springTarget: IslandView?
    @State private var springWork: DispatchWorkItem?

    /// How long a drag rests on a slot before the panel goes there. The same beat a Finder
    /// window's spring-loaded folder takes: long enough that passing over one does nothing,
    /// short enough that waiting on purpose is not waiting.
    static let springDelay: TimeInterval = 0.45

    /// The size a slot likes to be, and the smallest it will accept before slots start being
    /// dropped. Sections can be switched on and off, so the row has to hold anything from two
    /// to every one of them without changing the panel's width.
    static let slot: CGFloat = 26
    static let minSlot: CGFloat = 21
    static let gap: CGFloat = 4
    static let minGap: CGFloat = 2
    static let inset: CGFloat = 16
    /// Room kept clear either side of the physical cutout.
    static let cutoutMargin: CGFloat = 10
    /// What stands in for the cutout as the divider between the two groups on a screen with
    /// none: enough that they read as two groups, no more.
    static let groupGap: CGFloat = 14

    private var ring: [IslandView] { center.ring }

    /// The namespace the selected slot's disc travels in, and the one name it goes by.
    @Namespace private var selection
    private static let selectionID = "switcherSelection"

    private var cards: [IslandView] {
        ring.filter { if case .activity = $0 { return true } else { return false } }
    }

    private var sections: [IslandView] {
        ring.filter { if case .home = $0 { return true } else { return false } }
    }

    /// The gap the cutout takes out of the middle of the band, plus its margins. Only
    /// `straddling` has one.
    private var middle: CGFloat { geometry.notchWidth + Self.cutoutMargin * 2 }

    var body: some View {
        band
            .padding(.horizontal, Self.inset)
            // The row is centred on the notch, not on the band: the band is a couple of points
            // taller so it straddles the cutout, and centring in that would sit every glyph
            // lower than the menu bar items either side of it. The extra goes below.
            .frame(width: IslandLayout.panelWidth, height: geometry.notchHeight)
            .frame(height: geometry.notchHeight + IslandLayout.bandExtra, alignment: .top)
            // The slots themselves arrive and leave; the name under the pointer and the disc
            // that marks the view you are on only change where they are or how they look.
            .animation(IslandMotion.content, value: ring)
            .animation(IslandMotion.fade, value: label)
            .animation(IslandMotion.navigate, value: current)
    }

    @ViewBuilder
    private var band: some View {
        if geometry.hasPhysicalNotch { straddling } else { single }
    }

    /// A screen with a cutout: the live activities to its left, the sections to its right, and
    /// the cutout itself as the divider between them.
    private var straddling: some View {
        let width = IslandLayout.panelWidth
        let side = (width - middle) / 2 - Self.inset
        // The sections decide the size — there are always more of them — and the activity
        // slots on the other side of the cutout take the same one, so the band reads as one
        // row of buttons rather than two rows of different circles.
        let right = Self.fit(sections, in: side)
        let left = Self.fit(cards, in: side - Self.closeRoom, slot: right.slot, gap: right.gap)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                closeButton(size: right.slot)
                // A step, not a gap: closing the panel is not the next thing along the row
                // from the things that navigate it, and at four points it read as the first
                // of them.
                Color.clear.frame(width: Self.groupGap)
                // Identified by the view, not by where it sits: a slot arriving pushes the
                // others across and fades in beside them, where by position every glyph after
                // it would swap symbol in place and nothing would appear to have moved.
                HStack(spacing: left.gap) {
                    ForEach(left.views, id: \.self) { view in slotView(view, size: left.slot) }
                }
                Spacer(minLength: 0)
                // The left of the band is empty unless something is live, and a row of small
                // round glyphs says nothing about itself. So the name of whatever the pointer
                // is on appears here, against the cutout, for as long as it is on it.
                if left.views.isEmpty, let name = label { hoverName(name) }
            }
            .frame(width: side, alignment: .leading)
            Color.clear.frame(width: middle)
            HStack(spacing: right.gap) {
                ForEach(right.views, id: \.self) { view in slotView(view, size: right.slot) }
                Spacer(minLength: 0)
            }
            .frame(width: side, alignment: .leading)
        }
    }

    /// A screen with none: one row from the leading edge — the close button, then the
    /// activities, then a step of space before the sections, so the two groups still read as
    /// two. Split down the middle it left the whole left half of the band empty and every
    /// glyph sitting right of centre, around a camera housing that is not there.
    private var single: some View {
        let step: CGFloat = cards.isEmpty ? 0 : Self.groupGap
        let row = Self.fit(cards + sections, in: IslandLayout.panelWidth - Self.inset * 2 - Self.closeRoom - step)
        let shownCards = Array(row.views.prefix(cards.count))
        let shownSections = Array(row.views.dropFirst(cards.count))
        // Spaced by hand rather than by the stack, so the step between the two groups is the
        // step and not the step plus a gap either side of it — which is what the row was
        // measured for.
        return HStack(spacing: 0) {
            closeButton(size: row.slot)
            Color.clear.frame(width: Self.groupGap)
            HStack(spacing: row.gap) {
                ForEach(shownCards, id: \.self) { view in slotView(view, size: row.slot) }
            }
            if !shownCards.isEmpty { Color.clear.frame(width: step) }
            HStack(spacing: row.gap) {
                ForEach(shownSections, id: \.self) { view in slotView(view, size: row.slot) }
            }
            if let name = label { hoverName(name).padding(.leading, 8) }
            Spacer(minLength: 0)
        }
    }

    /// The name of whatever the pointer is on, so a row of small round glyphs says something
    /// about itself.
    private func hoverName(_ name: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            // The key that goes straight here, where somebody is already looking to find out
            // how to get here. Only while the digits are actually the island's, and only for
            // the nine slots a digit can reach.
            if let digit = hoveredDigit {
                Text(digit)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .transition(.opacity)
        .id(name)
        .accessibilityHidden(true)
    }

    /// The digit that jumps to the slot the pointer is on, when there is one.
    private var hoveredDigit: String? {
        guard center.panelKeysActive, let hovered,
              let index = center.ring.firstIndex(of: hovered), index < 9 else { return nil }
        return String(index + 1)
    }

    /// The name of the slot the pointer is on. Only while the pointer is on one, and never
    /// for the one you are already looking at: that section says what it is in its own
    /// header, and two labels for one thing is one too many. Clicking a slot leaves the
    /// pointer on it, so without this the name you just chose was printed twice on the same
    /// screen for as long as the hand stayed still.
    ///
    /// A drag resting on a slot names it too, and for the same reason: it is the one place
    /// that can say where holding still is about to take you.
    private var label: String? {
        guard let on = springTarget ?? hovered, on != current else { return nil }
        return Self.entry(for: on, center: center).title
    }

    // MARK: - Spring loading

    /// A drag arriving on a slot, or leaving it. Holding still on one opens it, so a file can
    /// be carried to a section that takes drops of its own — a quick action, a window's tile —
    /// without putting it down first. Passing over a slot on the way somewhere else does
    /// nothing, which is what the pause is for.
    private func springLoad(_ view: IslandView, inside: Bool) {
        springWork?.cancel()
        springWork = nil
        // A slot taking the drag takes it off the island's own drop target, and the island is
        // told the drag has left. It has not: it is right here.
        center.holdDrag(inside)
        guard inside else {
            if springTarget == view { springTarget = nil }
            return
        }
        springTarget = view
        guard view != current else { return }
        // Settled now rather than in the closure, where the ring may have moved under it.
        let step = direction(to: view)
        let work = DispatchWorkItem {
            // The drag may have moved on in the meantime; only the slot it is still on opens.
            guard springTarget == view else { return }
            Haptics.tap()
            ActivityCenter.shared.select(view, direction: step)
        }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDelay, execute: work)
    }

    /// How to lay a row of slots out in the room there is: at the size they like where they
    /// all fit, tighter where they do not, and only then fewer of them. Every section the user
    /// switched on should be one click away, so the row gives up its spacing before it gives
    /// up a slot.
    static func fit(_ views: [IslandView], in room: CGFloat) -> (views: [IslandView], slot: CGFloat, gap: CGFloat) {
        guard !views.isEmpty, room > 0 else { return ([], slot, gap) }
        let count = CGFloat(views.count)
        if count * slot + (count - 1) * gap <= room { return (views, slot, gap) }
        let tight = (room - (count - 1) * minGap) / count
        if tight >= minSlot { return (views, min(slot, tight.rounded(.down)), minGap) }
        // Even at the smallest size they do not all fit: drop the ones at the end.
        let fits = max(0, Int((room + minGap) / (minSlot + minGap)))
        return (Array(views.prefix(fits)), minSlot, minGap)
    }

    /// The same, at a size somebody else has already settled on: only the number of slots is
    /// decided here.
    static func fit(_ views: [IslandView], in room: CGFloat, slot: CGFloat, gap: CGFloat)
        -> (views: [IslandView], slot: CGFloat, gap: CGFloat) {
        guard !views.isEmpty, room > 0 else { return ([], slot, gap) }
        let fits = max(0, Int((room + gap) / (slot + gap)))
        return (Array(views.prefix(fits)), slot, gap)
    }

    private func slotView(_ view: IslandView, size: CGFloat) -> some View {
        let entry = Self.entry(for: view, center: center)
        let selected = current == view
        let springing = springTarget == view
        return Button(action: { center.select(view, direction: direction(to: view)) }) {
            ZStack {
                // One disc, moved from slot to slot, rather than one fading out where it was
                // while another fades in where you are going. A mark that travels tells you
                // which way you just went; two cross-fades tell you nothing.
                if selected {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: Self.selectionID, in: selection)
                }
                // Lit the way every other destination in the app is while something is held
                // over it, so a slot that is about to open looks like one.
                Circle().fill(Color.accentColor.opacity(springing ? 0.55 : 0))
                Image(systemName: entry.symbol)
                    .font(.system(size: size * 0.54, weight: .semibold))
                    .foregroundStyle(selected || springing ? Color.white : entry.tint.opacity(0.55))
            }
            .frame(width: size, height: size)
            .scaleEffect(springing ? 1.12 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .animation(IslandMotion.hover, value: springing)
        .onHover { inside in
            if inside { hovered = view } else if hovered == view { hovered = nil }
        }
        // Carry a file to a section rather than putting it down first: hold it on a slot and
        // the panel goes there. Dropping on the slot itself is a drop on the island, which
        // means the shelf, the way it does anywhere else on the band.
        .islandDrop(isTargeted: Binding(
            get: { springTarget == view },
            set: { inside in springLoad(view, inside: inside) }
        )) { providers in
            guard Preferences.shared.shelfEnabled else { return false }
            return ShelfStore.shared.acceptDrop(providers)
        }
        .help(entry.title)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Room the close button keeps at the leading edge whether or not it is showing: the
    /// button and the step that separates it from the row it is not part of. Kept whether or
    /// not it is showing, or the slots would resize and shuffle along the moment a peeked
    /// panel is pinned.
    static var closeRoom: CGFloat { slot + groupGap }

    /// The same circle as a slot, so the row is one size across.
    ///
    /// At the leading edge, where every window on the Mac keeps the button that closes it —
    /// and where it gives the band something at both ends. Sitting last, it left the whole
    /// left of a band with nothing live on it empty and every glyph in the panel crowded into
    /// the right third.
    private func closeButton(size: CGFloat) -> some View {
        Button(action: { center.collapse(reason: "close button") }) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .opacity(center.isOpen ? 1 : 0)
        .allowsHitTesting(center.isOpen)
        .help("Close")
        .accessibilityLabel("Close")
        .accessibilityHidden(!center.isOpen)
    }

    /// Which way the content pushes when jumping to `view`: the direction it sits in the ring.
    private func direction(to view: IslandView) -> Int {
        guard let current, let from = ring.firstIndex(of: current), let to = ring.firstIndex(of: view) else { return 0 }
        return to == from ? 0 : (to > from ? 1 : -1)
    }

    struct Entry {
        var symbol: String
        var title: String
        var tint: Color
    }

    static func entry(for view: IslandView, center: ActivityCenter) -> Entry {
        switch view {
        case .home(let tab):
            let section = HomeSection(rawValue: tab) ?? .music
            return Entry(symbol: section.symbol, title: section.title, tint: .white)
        case .activity(let id):
            guard let a = center.activity(id: id) else { return Entry(symbol: "circle", title: "Activity", tint: .white) }
            switch a.content {
            case .timer(let t): return Entry(symbol: t.isFinished ? "bell.fill" : "timer", title: t.label, tint: .orange)
            case .stopwatch: return Entry(symbol: "stopwatch.fill", title: "Stopwatch", tint: .orange)
            case .call(let c): return Entry(symbol: "phone.fill", title: "Call in \(c.appName)", tint: .green)
            case .battery(let b): return Entry(symbol: b.isCharging || b.isPluggedIn ? "battery.100percent.bolt" : "battery.50percent",
                                               title: b.title, tint: b.tint)
            case .bluetooth(let d): return Entry(symbol: d.symbol, title: d.name, tint: .white)
            case .focus(let f): return Entry(symbol: f.symbol, title: f.name, tint: Color.named(f.tint))
            case .hud(let h): return Entry(symbol: h.symbolName, title: h.title, tint: .white)
            case .calendar(let c): return Entry(symbol: "calendar", title: c.title, tint: Color.named(c.tint))
            case .download(let d): return Entry(symbol: d.isComplete ? "checkmark" : "arrow.down", title: d.name, tint: Color.named("blue"))
            case .drive(let d): return Entry(symbol: d.symbol, title: d.name, tint: Color.named(d.tint))
            case .capture(let c): return Entry(symbol: c.symbol, title: c.title, tint: Color.named("blue"))
            case .custom(let c): return Entry(symbol: c.symbol, title: c.title, tint: Color.named(c.tint))
            case .nowPlaying: return Entry(symbol: HomeSection.music.symbol, title: HomeSection.music.title, tint: .white)
            case .shelf: return Entry(symbol: HomeSection.shelf.symbol, title: HomeSection.shelf.title, tint: .white)
            case .silent: return Entry(symbol: "bell.slash.fill", title: "Silent", tint: .white)
            case .unlock: return Entry(symbol: "lock.open.fill", title: "Unlocked", tint: .white)
            }
        }
    }
}
