import AppKit
import SwiftUI

/// Now Playing, laid out the way the iPhone lays it out: artwork with the title and artist
/// beside it, the output on the trailing edge, then the scrubber and the transport. The
/// volume lives on the rail below, where it is under every section.
struct MusicSectionView: View {
    let geometry: NotchGeometry
    @ObservedObject private var service = NowPlayingService.shared
    /// Not observed: the section only says when it comes and goes (`viewerAppeared`), and draws
    /// nothing of the outputs'. Observed, every step of a volume drag on the rail — sixty to a
    /// hundred and twenty a second — drew the whole section again.
    private let outputs = AudioOutputs.shared
    @ObservedObject private var energy = EnergyPolicy.shared
    @EnvironmentObject private var prefs: Preferences

    /// What the service reports, or what the island's Now Playing activity carries when the
    /// service has nothing yet (a report still in flight, a rendered gallery).
    ///
    /// The centre is read, not observed. The service writes its track and the activity in the
    /// same turn of the main queue (`NowPlayingService.publish`, `clear`), so a change to the
    /// activity comes with a change to the service, which this does observe; a gallery draws
    /// the section afresh. Observed, the section was drawn again for everything else the centre
    /// publishes — a hover, a press, the microphone, the find bar.
    private var info: NowPlayingInfo? {
        if let info = service.info { return info }
        if case .nowPlaying(let info)? = ActivityCenter.shared.activity(id: "nowplaying")?.content { return info }
        return nil
    }

    var body: some View {
        Group {
            if let info {
                player(info)
            } else {
                SectionEmptyState(symbol: "play.circle", title: "Nothing playing") {
                    PillButton(title: "Open Music") { Self.openPlayer() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { outputs.viewerAppeared() }
        .onDisappear { outputs.viewerDisappeared() }
    }

    /// One size for every transport glyph. 24 pt is what the phone's island uses: big enough
    /// to hit with a pointer, small enough that three of them are a row rather than a bar.
    static let transportGlyph: CGFloat = 24
    /// The row the three of them sit on, and the square each takes its click in. The section
    /// is 140 pt and what stands above this — the 60 pt artwork row, 8 pt, and the 32 pt
    /// scrubber block — takes 100 of it, so 36 and the 4 above it fill the rest exactly. It was
    /// 34, which left 2 pt of the section unused, and the buttons kept their own 42 pt frames
    /// inside it, reaching 4 pt over the scrubber's times above and 4 pt past the row below.
    static let transportRow: CGFloat = 36
    /// The glyphs' centres stay 72 pt apart, as they were with the wider frames.
    static let transportSpacing: CGFloat = 72 - transportRow

    private func player(_ info: NowPlayingInfo) -> some View {
        let accent = Color(nsColor: info.accent)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                // No glow of the cover's colour under it either, for the same reason there is
                // no wash behind the row (see the foot of this view) — and the section's clip
                // cut the glow square 12 pt to the left of the cover and 8 pt above it.
                ArtworkView(image: info.artwork, size: 60, radius: 13, flexible: true)
                    .id(info.artworkID)
                    .transition(IslandMotion.pop(scale: 0.85))
                    // See `CompactLeadingView`: the pop needs a curve of its own to run on.
                    .animation(IslandMotion.fade, value: info.artworkID)
                    .islandMatched(IslandMatchedID.nowPlayingArtwork)
                    .onTapGesture { service.openApp() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Open \(info.appName)")
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: info.title.isEmpty ? "Unknown track" : info.title,
                                font: .system(size: 15, weight: .semibold), color: .white, isPlaying: info.isPlaying)
                    MarqueeText(text: info.artist.isEmpty ? info.appName : info.artist,
                                font: .system(size: 13, weight: .regular), color: .white.opacity(0.55),
                                isPlaying: info.isPlaying)
                }
                .padding(.top, 9)
                // The output picker used to stand here. It is on the control rail now, where
                // it is under every section and there whether or not anything is playing —
                // and where it is not a second copy of a control this row already had.
                VisualizerBars(isPlaying: info.isPlaying, color: accent.opacity(0.9),
                               barCount: 4, barWidth: 3, maxHeight: 18, minHeight: 4)
                    .islandMatched(IslandMatchedID.nowPlayingVisualizer)
                    .padding(.top, 16)
            }
            .frame(height: 60)

            // Several times a second while playing, so the fill creeps rather than steps: once
            // a second it jumped nearly four points at a time along a three-minute track.
            // Paused, nothing moves and nothing is redrawn.
            TimelineView(.animation(minimumInterval: max(0.25, energy.animationInterval), paused: !info.isPlaying)) { context in
                let position = info.position(at: context.date)
                let duration = info.duration
                VStack(spacing: 4) {
                    // A stream has no length and nowhere to seek to: the bar is a line, and a
                    // click on it is not a seek to 0:00. See `NowPlayingInfo.canSeek`.
                    ScrubberView(progress: duration > 0 ? position / duration : 0) { fraction in
                        service.seek(to: fraction * duration)
                    }
                    .disabled(!info.canSeek)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(IslandAccessibility.playbackValue(position: position, duration: duration))
                    TimesOrLyric(position: position, duration: duration, showsLyrics: prefs.lyricsEnabled)
                }
            }
            .padding(.top, 8)

            // One size and one weight for all three, the way the phone's island sets them.
            // A 30 pt `pause.fill` beside 22 pt triangles is a third again as much ink in the
            // middle of the row: the two skips read as faint and the row lost its centre.
            // The places beside play come either side of the three, at their size and weight and
            // on the same 72 pt pitch, so the row grows outwards and play never leaves the middle.
            let sides = TransportSlot.sides(TransportSlot.resolved(stored: prefs.transportSlots))
            HStack(spacing: Self.transportSpacing) {
                ForEach(Array(sides.left.enumerated()), id: \.offset) { pair in
                    slotButton(pair.element, info: info)
                }
                GlyphButton(symbol: "backward.fill", size: Self.transportGlyph, weight: .medium,
                            hit: Self.transportRow) { service.previous() }
                GlyphButton(symbol: info.isPlaying ? "pause.fill" : "play.fill",
                            size: Self.transportGlyph, weight: .medium, hit: Self.transportRow) { service.togglePlayPause() }
                    .animation(IslandMotion.fade, value: info.isPlaying)
                GlyphButton(symbol: "forward.fill", size: Self.transportGlyph, weight: .medium,
                            hit: Self.transportRow) { service.next() }
                ForEach(Array(sides.right.enumerated()), id: \.offset) { pair in
                    slotButton(pair.element, info: info)
                }
            }
            .frame(height: Self.transportRow)
            .padding(.top, 4)
        }
        // No wash of the cover's colour behind the row. There was one — the cover blurred out
        // into the black and masked off towards the bottom, the way the phone tints its card —
        // and on the island it read as a smear beside the artwork rather than as a colour.
        // The island is black; the cover is the only colour in it, and it is enough.
    }

    /// One of the places beside play. An empty one is a blank square that keeps play in the
    /// middle. A button the player does not honour is drawn at a quarter strength and does not
    /// take the click — the row keeps its shape from one player to the next, and the dim glyph
    /// says the button is there for the players that do. A lit one — shuffle on, a repeat, a
    /// favourite — takes the cover's colour, with a dot under it for the covers whose colour
    /// is nearly white.
    ///
    /// A lit heart the player cannot be asked to empty (`NowPlayingService.heartPress`) keeps
    /// its colour at half strength and does not take the click: the track is still a
    /// favourite, and the tooltip says where to take it back.
    @ViewBuilder
    private func slotButton(_ slot: TransportSlot, info: NowPlayingInfo) -> some View {
        if slot == .empty {
            Color.clear
                .frame(width: Self.transportRow, height: Self.transportRow)
                .accessibilityHidden(true)
        } else {
            let liked = service.isLiked(info)
            let supported = slot.isSupported(by: info)
            let on = supported && slot.isOn(in: info, liked: liked)
            let settled = on && slot == .favourite
                && NowPlayingService.heartPress(liked: liked, active: service.activeBackend, info: info) == .settled
            let fullLit = Color(nsColor: info.accent.blended(withFraction: 0.35, of: .white) ?? info.accent)
            let lit = settled ? fullLit.opacity(0.5) : fullLit
            GlyphButton(symbol: slot.symbol(in: info, liked: liked), size: Self.transportGlyph,
                        tint: !supported ? Color.white.opacity(0.25) : (on ? lit : Color.white),
                        weight: .medium, label: slot.spokenName, hit: Self.transportRow) {
                perform(slot)
            }
            .overlay(alignment: .bottom) {
                if on {
                    Circle()
                        .fill(lit)
                        .frame(width: 4, height: 4)
                        .padding(.bottom, 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .disabled(!supported || settled)
            .accessibilityValue(slot.spokenValue(in: info, liked: liked) ?? "")
            .help(helpText(for: slot, supported: supported, settled: settled, info: info))
            .animation(IslandMotion.fade, value: on)
        }
    }

    /// The tooltip: what the button is, or why it will not take the click.
    private func helpText(for slot: TransportSlot, supported: Bool, settled: Bool, info: NowPlayingInfo) -> String {
        if !supported { return "\(slot.title) — \(info.appName) does not offer this" }
        if settled { return "Favourited — take it back in \(info.appName)" }
        // The player has refused the island under Automation, so a press this row sends it by
        // script goes nowhere; the tooltip is where that can be said, and where to change it.
        if AppleScriptBackend.hasRefused(info.bundleID) {
            return "\(slot.title) — \(info.appName) refused Notch Island under Automation in Privacy & Security"
        }
        return slot.title
    }

    private func perform(_ slot: TransportSlot) {
        switch slot {
        case .empty: break
        case .shuffle: service.toggleShuffle()
        case .cycleRepeat: service.cycleRepeat()
        case .favourite: service.toggleFavourite()
        case .back15: service.skip(by: -15)
        case .forward15: service.skip(by: 15)
        }
    }

    /// The app that last played, else Music.
    static func openPlayer() {
        if let bundle = NowPlayingService.shared.info?.bundleID {
            OpenAction.app(bundleID: bundle).perform()
        } else {
            OpenAction.app(bundleID: "com.apple.Music").perform()
        }
    }
}

/// The times under the scrubber, or the line of the song in their place when there is one.
///
/// The one part of the section that reads the lyrics. The section read them itself, so every
/// new line redrew all of it — the artwork, both marquees and the transport — to change one
/// row; here a line redraws the row.
private struct TimesOrLyric: View {
    let position: TimeInterval
    let duration: TimeInterval
    let showsLyrics: Bool
    @ObservedObject private var lyrics = LyricsService.shared

    private var hasLine: Bool {
        guard showsLyrics, let line = lyrics.currentLine?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !line.isEmpty
    }

    var body: some View {
        ZStack {
            HStack {
                Text(position.mmss)
                Spacer()
                Text(duration > 0 ? "-" + max(0, duration - position).mmss : "")
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
            .opacity(hasLine ? 0 : 1)
            if showsLyrics {
                LyricsView(font: .system(size: 12, weight: .semibold), color: .white.opacity(0.85), lineHeight: 14)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 14)
    }
}
