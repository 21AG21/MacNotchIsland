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
    @State private var hovered: HomeSection?

    /// Five columns and two rows fill the section exactly; Now Playing takes two of the five,
    /// which leaves three beside it and up to five underneath — room for every section there
    /// is with one to spare.
    static let columns = 5
    static let gap: CGFloat = 10
    static let radius: CGFloat = 12
    static var tileWidth: CGFloat {
        ((IslandLayout.panelContentWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
    }
    static var tileHeight: CGFloat { ((IslandLayout.sectionHeight - gap) / 2).rounded(.down) }
    static var wideWidth: CGFloat { tileWidth * 2 + gap }

    private var tiles: [HomeSection] { HomeSection.tiles(prefs) }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                nowPlayingTile
                ForEach(Array(tiles.prefix(3)), id: \.self) { tile($0) }
                Spacer(minLength: 0)
            }
            HStack(spacing: Self.gap) {
                ForEach(Array(tiles.dropFirst(3).prefix(Self.columns)), id: \.self) { tile($0) }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(IslandMotion.hover, value: hovered)
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

    private var nowPlayingTile: some View {
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
            .frame(width: Self.wideWidth, height: Self.tileHeight)
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

    private func tile(_ section: HomeSection) -> some View {
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
            .frame(width: Self.tileWidth, height: Self.tileHeight, alignment: .topLeading)
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
    private func glimpse(_ section: HomeSection) -> String {
        switch section {
        case .home, .music: return ""
        case .today: return agendaGlimpse
        case .controls: return "Wi-Fi and Bluetooth"
        case .windows: return "Every open window"
        case .shelf: return shelf.items.isEmpty ? "Drop files here" : count(shelf.items.count, "item")
        case .clipboard: return clipboard.items.isEmpty ? "Nothing copied yet" : count(clipboard.items.count, "item")
        case .actions:
            let total = runner.favorites.count + apps.apps.count
            return total == 0 ? "Shortcuts and apps" : count(total, "action")
        case .notes:
            let first = notes.text.split(separator: "\n").first.map(String.init) ?? ""
            return first.isEmpty ? "Jot something down" : first
        case .stats: return "Processor and memory"
        }
    }

    private var agendaGlimpse: String {
        if let next = agenda.events.first { return next.title }
        if let todo = agenda.reminders.first { return todo.title }
        return "Nothing today"
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}
