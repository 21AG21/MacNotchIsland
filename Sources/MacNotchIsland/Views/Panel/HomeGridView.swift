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
    /// Which island this grid is drawn on, so a panel pinned on another display does not count
    /// as this one being pinned — see `agendaHoldNow`.
    @Environment(\.islandPanelID) private var panelID
    // Not what is playing: that is the Now Playing tile's to watch (`NowPlayingTile`). Every
    // store here is one a tile's line reads.
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var notes = NotesStore.shared
    @ObservedObject private var runner = ShortcutsRunner.shared
    @ObservedObject private var apps = FavoriteApps.shared
    @ObservedObject private var agenda = AgendaStore.shared
    @ObservedObject private var inbox = NotificationInbox.shared
    /// How this view holds the agenda, see `agendaHold`.
    @State private var heldAgenda = AgendaStore.Hold.off

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

    var body: some View {
        // Read once a pass: it walks the sections and the preferences, and it was read three times.
        let tiles = HomeSection.tiles(prefs)
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
                NowPlayingTile(width: Self.wideWidth(columns: columns)) { open(.music) }
                ForEach(Array(tiles.prefix(acrossTheTop)), id: \.self) { tile($0, width: width) }
            }
            HStack(spacing: Self.gap) {
                ForEach(Array(tiles.dropFirst(acrossTheTop).prefix(columns)), id: \.self) { tile($0, width: width) }
            }
        }
        .frame(width: Self.gridWidth(columns: columns), alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The Today tile's line is read from the agenda, and the agenda only reads the day
        // while somebody is looking at it: unregistered, the tile said "Nothing today" after
        // a fresh launch and, later on, named a meeting that had ended hours before. Held on
        // the same terms as the calendar itself, so the tile never asks for it ahead of the
        // tour — and asks only on a panel somebody opened.
        .onAppear { holdAgenda(agendaHoldNow) }
        .onDisappear { holdAgenda(.off) }
        .onChange(of: agendaHoldNow) { _, hold in holdAgenda(hold) }
    }

    /// How this grid should hold the agenda at this moment, see `agendaHold`. Two stored
    /// switches and what is published about the open panel: nothing here asks macOS anything
    /// on a pass of the body.
    ///
    /// Pinned means pinned on this island (`openHere`), not open somewhere: with the panel
    /// pinned on one display, the grid in the other's peek counted as pinned, held the agenda
    /// as a viewer that may ask, and could put the Calendars or Reminders sheet up under a
    /// pointer that had only crossed the top of that screen. `openHere` reads the published
    /// open view and the island it is on, so the hold is asked again when the panel moves.
    private var agendaHoldNow: AgendaStore.Hold {
        Self.agendaHold(wantsCalendar: ServiceHub.wantsCalendar(prefs), pinnedOpen: center.openHere(panelID))
    }

    /// How the grid holds the agenda.
    ///
    /// The grid is also the peek that opens under a pointer resting on the bare notch, and a
    /// viewer that may ask is what puts the Reminders sheet up — which came up because
    /// somebody's pointer had crossed the top of the screen. So a peek reads the day and asks
    /// for nothing (`AgendaStore.Hold.reading`), which keeps its Today tile as fresh as the
    /// pinned one's with whatever has been granted; a panel pinned open, which somebody chose
    /// to open, may put the questions. A peek used to stay off the agenda while a question was
    /// still to be put, and after the tour one always is — Reminders — so a new Mac's peek said
    /// "Nothing today" over a day of meetings. Pure.
    static func agendaHold(wantsCalendar: Bool, pinnedOpen: Bool) -> AgendaStore.Hold {
        guard wantsCalendar else { return .off }
        return pinnedOpen ? .asking : .reading
    }

    /// Moves this view's hold on the agenda — what it gives back on the way out is what it
    /// took, whatever the switch says by then.
    private func holdAgenda(_ hold: AgendaStore.Hold) {
        guard hold != heldAgenda else { return }
        agenda.move(from: heldAgenda, to: hold)
        heldAgenda = hold
    }

    // MARK: - The rest

    private func tile(_ section: HomeSection, width: CGFloat) -> some View {
        // Once a pass: the line is both shown and spoken, and the Today tile's walks the agenda.
        let glimpse = self.glimpse(section)
        return HomeTile(width: width, alignment: .topLeading, action: { open(section) }) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 2)
                Text(section.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(glimpse)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(10)
        }
        .accessibilityLabel("\(section.title), \(glimpse)")
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
        case .notes: return Self.notesGlimpse(notes.text)
        case .stats: return "CPU, memory"
        case .notifications:
            return inbox.entries.isEmpty ? "Nothing yet" : count(inbox.entries.count, "notification")
        }
    }

    /// The Notes tile's line: the scratchpad's first line with anything on it, else "Jot it
    /// down". Pure, so the rule is tested.
    ///
    /// Read as far as the end of that line and no further. The tile split the whole scratchpad
    /// at every line break — and the scratchpad has no cap — to keep the first piece, twice a
    /// pass, the second time for its spoken label. Blank lines before it are passed over, as
    /// the split passed them over; the whole line is kept, since it is spoken whole.
    static func notesGlimpse(_ text: String) -> String {
        guard let start = text.firstIndex(where: { $0 != "\n" }) else { return "Jot it down" }
        let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
        return String(text[start..<end])
    }

    private var agendaGlimpse: String {
        Self.agendaGlimpse(events: agenda.events, reminders: agenda.reminders, at: Date())
    }

    /// The Today tile's line: the first of today's events that is not over, else the first
    /// reminder still open, else "Nothing today". Pure, so the rule is tested.
    ///
    /// Today as the Today section counts it (`TodaySectionView.day`). The agenda reads the next
    /// twenty-four hours, timed events before all-day ones, and the tile took the first of them
    /// that had not ended: in the evening it named tomorrow morning's meeting while the section
    /// said "Nothing left today", and tomorrow's timed event came before today's all-day one.
    /// The day's reminders are the open ones, so one just ticked off is not named either. Not
    /// over yet on top of that: the list is only as fresh as its last reading, and a meeting
    /// that has ended is not what is next.
    static func agendaGlimpse(events: [AgendaStore.Event], reminders: [AgendaStore.Reminder], at now: Date,
                              calendar: Calendar = .current) -> String {
        let today = TodaySectionView.day(events: events, reminders: reminders, at: now, calendar: calendar)
        if let next = today.events.first(where: { $0.end > now }) { return next.title }
        if let todo = today.reminders.first { return todo.title }
        return "Nothing today"
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}

/// Two tiles wide, because it is the one thing the island is for: the cover, what it is, and
/// the one control anybody reaches for without thinking.
///
/// A view of its own, and the one part of the grid that watches the service: a report comes
/// several times a track and with every press, and the grid used to be drawn again, every tile
/// and every tile's line, for each of them.
private struct NowPlayingTile: View {
    let width: CGFloat
    let action: () -> Void
    @ObservedObject private var playing = NowPlayingService.shared

    /// What the service reports, or what the island's Now Playing activity carries when the
    /// service has nothing yet — a report still in flight, or a rendered gallery. The same
    /// fallback the Now Playing section makes, for the same reason, and read the same way
    /// (`MusicSectionView.info`): the service moves the activity in the same turn as its track.
    private var info: NowPlayingInfo? {
        if let info = playing.info { return info }
        if case .nowPlaying(let info)? = ActivityCenter.shared.activity(id: "nowplaying")?.content { return info }
        return nil
    }

    var body: some View {
        let info = self.info
        // Once a pass: it is both shown and spoken, and with no artist it is the player's name.
        let subtitle = Self.subtitle(for: info)
        return HomeTile(width: width, action: action) {
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
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if info != nil {
                    // The tile is a button; this one sits on top of it and does its own thing,
                    // the way the play button on a Music widget does — to a pointer. VoiceOver
                    // reads a button's label as the one element, and a button inside that label
                    // cannot be counted on to be an element of its own: play and pause are the
                    // tile's named action instead (`PlayPauseAction`), and this copy is kept out
                    // of the way so the one path to them is that action.
                    GlyphButton(symbol: info?.isPlaying == true ? "pause.fill" : "play.fill",
                                size: 15, weight: .semibold) {
                        playing.togglePlayPause()
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
        }
        .accessibilityLabel(info == nil ? "Now Playing, nothing playing"
                                        : "Now Playing, \(info?.title ?? ""), \(subtitle)")
        .modifier(PlayPauseAction(isPlaying: info?.isPlaying) { playing.togglePlayPause() })
    }

    private static func subtitle(for info: NowPlayingInfo?) -> String {
        guard let info else { return "Open Now Playing" }
        return info.artist.isEmpty ? info.appName : info.artist
    }
}

/// A tile of the grid: its button, and its ground, which lights while the pointer is over it.
///
/// The hover is the tile's own. It was the grid's, one value for every tile, so the pointer
/// crossing from one tile to the next drew the whole grid twice — every tile's line worked out
/// again, the Today tile's walk of the agenda and the Notes tile's reading of the scratchpad
/// with them — to change the shade of two.
private struct HomeTile<Content: View>: View {
    let width: CGFloat
    let alignment: Alignment
    let action: () -> Void
    let content: Content
    @State private var hovering = false

    init(width: CGFloat, alignment: Alignment = .center, action: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.width = width
        self.alignment = alignment
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(width: width, height: HomeGridView.tileHeight, alignment: alignment)
                .background(
                    RoundedRectangle(cornerRadius: HomeGridView.radius, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.14 : 0.07))
                )
                .contentShape(RoundedRectangle(cornerRadius: HomeGridView.radius, style: .continuous))
        }
        .buttonStyle(IslandButtonStyle())
        .onHover { hovering = $0 }
        .animation(IslandMotion.hover, value: hovering)
    }
}

/// Play and pause as a named action on the Now Playing tile, while there is something playing
/// to act on: the tile's own button is inside the tile's label, where VoiceOver cannot be
/// counted on to reach it.
private struct PlayPauseAction: ViewModifier {
    /// Nil with nothing playing, when the tile has no play button either.
    let isPlaying: Bool?
    let toggle: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let isPlaying {
            content.accessibilityAction(named: Text(isPlaying ? "Pause" : "Play")) { toggle() }
        } else {
            content
        }
    }
}
