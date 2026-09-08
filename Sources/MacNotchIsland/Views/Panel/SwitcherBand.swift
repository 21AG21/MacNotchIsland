import SwiftUI

/// The panel's top band, the one place the island has that nothing else needs: the live
/// activities' cards sit left of the camera cutout, the Home sections right of it, and the
/// cutout itself is the divider. Every view the panel can show is one click away here.
struct SwitcherBand: View {
    let geometry: NotchGeometry
    let current: IslandView?
    @EnvironmentObject private var center: ActivityCenter

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

    private var ring: [IslandView] { center.ring }

    private var cards: [IslandView] {
        ring.filter { if case .activity = $0 { return true } else { return false } }
    }

    private var sections: [IslandView] {
        ring.filter { if case .home = $0 { return true } else { return false } }
    }

    /// The gap in the middle: the cutout plus its margins on a notched screen, a plain gap on a
    /// floating island.
    private var middle: CGFloat {
        geometry.hasPhysicalNotch ? geometry.notchWidth + Self.cutoutMargin * 2 : 24
    }

    var body: some View {
        let width = IslandLayout.panelWidth
        let side = (width - middle) / 2 - Self.inset
        let closeRoom: CGFloat = center.isOpen ? Self.slot + 6 : 0
        let left = Self.fit(cards, in: side)
        let right = Self.fit(sections, in: side - closeRoom)
        HStack(spacing: 0) {
            HStack(spacing: left.gap) {
                ForEach(Array(left.views.enumerated()), id: \.offset) { _, view in slotView(view, size: left.slot) }
                Spacer(minLength: 0)
            }
            .frame(width: side, alignment: .leading)
            Color.clear.frame(width: middle)
            HStack(spacing: right.gap) {
                ForEach(Array(right.views.enumerated()), id: \.offset) { _, view in slotView(view, size: right.slot) }
                Spacer(minLength: 0)
                if center.isOpen { closeButton }
            }
            .frame(width: side, alignment: .leading)
        }
        .padding(.horizontal, Self.inset)
        .frame(width: width, height: geometry.notchHeight + IslandLayout.bandExtra)
        .animation(IslandMotion.quick, value: ring)
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

    private func slotView(_ view: IslandView, size: CGFloat) -> some View {
        let entry = Self.entry(for: view, center: center)
        let selected = current == view
        return Button(action: { center.select(view, direction: direction(to: view)) }) {
            ZStack {
                Circle().fill(Color.white.opacity(selected ? 0.14 : 0))
                Image(systemName: entry.symbol)
                    .font(.system(size: size * 0.54, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : entry.tint.opacity(0.55))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .help(entry.title)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var closeButton: some View {
        Button(action: { center.collapse(reason: "close button") }) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: Self.slot, height: Self.slot)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .help("Close")
        .accessibilityLabel("Close")
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
            case .custom(let c): return Entry(symbol: c.symbol, title: c.title, tint: Color.named(c.tint))
            case .nowPlaying: return Entry(symbol: HomeSection.music.symbol, title: HomeSection.music.title, tint: .white)
            case .shelf: return Entry(symbol: HomeSection.shelf.symbol, title: HomeSection.shelf.title, tint: .white)
            case .silent: return Entry(symbol: "bell.slash.fill", title: "Silent", tint: .white)
            case .unlock: return Entry(symbol: "lock.open.fill", title: "Unlocked", tint: .white)
            }
        }
    }
}
