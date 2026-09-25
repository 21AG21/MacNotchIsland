import AppKit
import SwiftUI

/// The panel's front door: what is playing, wide, and every other section as a tile beside it.
///
/// Control Centre's arrangement, for the same reason Control Centre has it — a row of small
/// glyphs beside the notch tells you a section exists but not what is in it, and somebody who
/// has just installed the app has no idea any of this is here. A tile says its name, and says
/// what is behind it before you go there.
struct HomeGridView: View {
    @EnvironmentObject private var center: ActivityCenter
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var playing = NowPlayingService.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var notes = NotesStore.shared
    @ObservedObject private var runner = ShortcutsRunner.shared
    @ObservedObject private var apps = FavoriteApps.shared
    @ObservedObject private var agenda = AgendaStore.shared
    @ObservedObject private var inbox = NotificationInbox.shared
    @State private var hovered: HomeSection?
    /// Whether this view is one of the agenda's viewers, see `holdAgenda`.
    @State private var holdsAgenda = false

    /// Two rows, and as many columns as it takes. Now Playing is two columns wide, so a
    /// five-column grid holds three tiles beside it and five underneath: eight sections.
    ///
    /// Switch on more than that and it goes to six rather than leave one of them off. The
    /// front door is where somebody who has just installed this finds out that any of the rest
    /// of it exists, and the band beside the notch cannot hold every section either — a
    /// section with no tile *and* no slot is a section nobody will ever find. Narrower tiles
    /// are a smaller price than an invisible one.
    static let columns = 5
    static let crowdedColumns = 6
    static let gap: CGFloat = 10
    static let radius: CGFloat = 12

    /// How many tiles a grid of this many columns can show: the row beside Now Playing, which
    /// is two columns poorer, and the whole row under it.
    static func capacity(columns: Int) -> Int { (columns - 2) + columns }

    /// The grid this many tiles need. It never goes past six: a seventh column would put the
    /// tiles under ninety points, where the name of a section stops fitting on one line, and
    /// at that point the honest answer is that the grid is full.
    static func columns(for count: Int) -> Int {
        count > capacity(columns: columns) ? crowdedColumns : columns
    }

    static func tileWidth(columns: Int) -> CGFloat {
        ((IslandLayout.panelContentWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
    }
    static var tileHeight: CGFloat { ((IslandLayout.sectionHeight - gap) / 2).rounded(.down) }
    static func wideWidth(columns: Int) -> CGFloat { tileWidth(columns: columns) * 2 + gap }
    /// What a full row of tiles comes to. The tiles are rounded down to whole points, so this
    /// falls a little short of the column — 2 pt at five columns, 4 at six.
    static func gridWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * tileWidth(columns: columns) + CGFloat(columns - 1) * gap
    }

    private var tiles: [HomeSection] { HomeSection.tiles(prefs) }

    var body: some View {
        let columns = Self.columns(for: tiles.count)
        let width = Self.tileWidth(columns: columns)
        // The wide tile eats two of the top row's columns.
        let acrossTheTop = columns - 2
        // The grid is exactly as wide as its tiles and centred in the column, so what the
        // rounding leaves over is shared by the two sides. Each row ended in a spacer, which
        // gave all of it to the right: at six columns the grid stood 24 pt in from the left of
        // the panel and 28 from the right. A row with fewer tiles still starts at the left of
        // the grid, so its tiles stay on the columns of the row above.
        return VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                nowPlayingTile(width: Self.wideWidth(columns: columns))
                ForEach(Array(tiles.prefix(acrossTheTop)), id: \.self) { tile($0, width: width) }
            }
            HStack(spacing: Self.gap) {
                ForEach(Array(tiles.dropFirst(acrossTheTop).prefix(columns)), id: \.self) { tile($0, width: width) }
            }
        }
        .frame(width: Self.gridWidth(columns: columns), alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(IslandMotion.hover, value: hovered)
        // The Today tile's line is read from the agenda, and the agenda only reads the day
        // while somebody is looking at it: unregistered, the tile said "Nothing today" after
        // a fresh launch and, later on, named a meeting that had ended hours before. Held on
        // the same terms as the calendar itself, so the tile never asks for it ahead of the
        // tour — and, while holding it would still ask, only on a panel somebody opened.
        .onAppear { holdAgenda(holdsAgendaNow) }
        .onDisappear { holdAgenda(false) }
        .onChange(of: holdsAgendaNow) { _, wanted in holdAgenda(wanted) }
    }

    /// Whether this grid should be one of the agenda's viewers at this moment, see `holdsAgenda`.
    private var holdsAgendaNow: Bool {
        Self.holdsAgenda(wantsCalendar: ServiceHub.wantsCalendar(prefs), pinnedOpen: center.isOpen,
                         wouldAsk: agenda.wouldAsk)
    }

    /// Whether the grid holds the agenda.
    ///
    /// The first viewer is what asks macOS for Reminders, and the grid is also the peek that
    /// opens under a pointer resting on the bare notch — so the Reminders sheet came up because
    /// somebody's pointer had crossed the top of the screen. While holding it would ask, it is
    /// held only on a panel pinned open, which somebody chose to open; once both questions have
    /// been put, a peek holds it too, so its Today tile is as fresh as the pinned one. Pure.
    static func holdsAgenda(wantsCalendar: Bool, pinnedOpen: Bool, wouldAsk: Bool) -> Bool {
        wantsCalendar && (pinnedOpen || !wouldAsk)
    }

    /// Takes or gives back this view's place among the agenda's viewers — what it gave back on
    /// the way out is what it took, whatever the switch says by then.
    private func holdAgenda(_ wanted: Bool) {
        guard wanted != holdsAgenda else { return }
        holdsAgenda = wanted
        if wanted { agenda.viewerAppeared() } else { agenda.viewerDisappeared() }
    }

    // MARK: - What is playing

    /// Two tiles wide, because it is the one thing the island is for: the cover, what it is,
    /// and the one control anybody reaches for without thinking.
    /// What the service reports, or what the island's Now Playing activity carries when the
    /// service has nothing yet — a report still in flight, or a rendered gallery. The same
    /// fallback the Now Playing section makes, for the same reason.
    private var info: NowPlayingInfo? {
        if let info = playing.info { return info }
        if case .nowPlaying(let info)? = center.activity(id: "nowplaying")?.content { return info }
        return nil
    }

    private func nowPlayingTile(width: CGFloat) -> some View {
        let info = self.info
        return Button(action: { open(.music) }) {
            HStack(spacing: 10) {
                if let info {
                    ArtworkView(image: info.artwork, size: 40, radius: 8, flexible: false)
                        .id(info.artworkID)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.10))
                        Image(systemName: "music.note")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(info?.title.isEmpty == false ? info!.title : "Nothing playing")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle(for: info))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if info != nil {
                    // The tile is a button; this one sits on top of it and does its own thing,
                    // the way the play button on a Music widget does.
                    GlyphButton(symbol: info?.isPlaying == true ? "pause.fill" : "play.fill",
                                size: 15, weight: .semibold) {
                        playing.togglePlayPause()
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: Self.tileHeight)
            .background(background(for: .music))
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(IslandButtonStyle())
        .onHover { inside in hover(.music, inside) }
        .accessibilityLabel(info == nil ? "Now Playing, nothing playing"
                                        : "Now Playing, \(info?.title ?? ""), \(subtitle(for: info))")
    }

    private func subtitle(for info: NowPlayingInfo?) -> String {
        guard let info else { return "Open Now Playing" }
        return info.artist.isEmpty ? info.appName : info.artist
    }

    // MARK: - The rest

    private func tile(_ section: HomeSection, width: CGFloat) -> some View {
        Button(action: { open(section) }) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 2)
                Text(section.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(glimpse(section))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(10)
            .frame(width: width, height: Self.tileHeight, alignment: .topLeading)
            .background(background(for: section))
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(IslandButtonStyle())
        .onHover { inside in hover(section, inside) }
        .accessibilityLabel("\(section.title), \(glimpse(section))")
    }

    private func background(for section: HomeSection) -> some View {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(Color.white.opacity(hovered == section ? 0.14 : 0.07))
    }

    private func hover(_ section: HomeSection, _ inside: Bool) {
        if inside { hovered = section } else if hovered == section { hovered = nil }
    }

    private func open(_ section: HomeSection) {
        center.select(.home(tab: section.rawValue), direction: 1)
    }

    /// The line under a tile's name: what is behind it, in as few words as it takes. A count
    /// where there is one to give, and what the section is for where there is not — a tile
    /// that says only its own name twice is a tile that has told you nothing.
    ///
    /// Short enough for a six-column tile, which leaves 83 pt for the words. "Processor and
    /// memory" did not fit even at five columns, and five more of these lost their last word
    /// to an ellipsis at six.
    private func glimpse(_ section: HomeSection) -> String {
        switch section {
        case .home, .music: return ""
        case .today: return agendaGlimpse
        case .controls: return "Wi-Fi, devices"
        // Not "every window": the section lists this desktop's, and the Dock's with them.
        case .windows: return "This desktop"
        case .shelf: return shelf.items.isEmpty ? "Drop files here" : count(shelf.items.count, "item")
        case .clipboard: return clipboard.items.isEmpty ? "Nothing copied" : count(clipboard.items.count, "item")
        case .actions:
            // What the row draws, not what the lists hold: lists saved before the row's cap
            // counted apps and Shortcuts together could add up to more than it shows.
            let fit = QuickActionsRowView.fit(apps: apps.inRow, shortcuts: runner.favorites.count)
            let total = fit.apps + fit.shortcuts
            return total == 0 ? "Shortcuts, apps" : count(total, "action")
        case .notes:
            let first = notes.text.split(separator: "\n").first.map(String.init) ?? ""
            return first.isEmpty ? "Jot it down" : first
        case .stats: return "CPU, memory"
        case .notifications:
            return inbox.entries.isEmpty ? "Nothing yet" : count(inbox.entries.count, "notification")
        }
    }

    private var agendaGlimpse: String {
        // Not over yet: the list is only as fresh as its last reading, and a meeting that has
        // ended is not what is next.
        if let next = agenda.events.first(where: { $0.end > Date() }) { return next.title }
        if let todo = agenda.reminders.first { return todo.title }
        return "Nothing today"
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}
