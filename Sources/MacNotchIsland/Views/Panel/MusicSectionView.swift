import AppKit
import SwiftUI

/// Now Playing, laid out the way the iPhone lays it out: artwork with the title and artist
/// beside it, the output on the trailing edge, then the scrubber and the transport. The
/// volume lives on the rail below, where it is under every section.
struct MusicSectionView: View {
    let geometry: NotchGeometry
    @ObservedObject private var service = NowPlayingService.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    @ObservedObject private var lyrics = LyricsService.shared
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var center: ActivityCenter

    /// What the service reports, or what the island's Now Playing activity carries when the
    /// service has nothing yet (a report still in flight, a rendered gallery).
    private var info: NowPlayingInfo? {
        if let info = service.info { return info }
        if case .nowPlaying(let info)? = center.activity(id: "nowplaying")?.content { return info }
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
    /// The row the three of them sit on. The section is 140 pt and what stands above this —
    /// the 60 pt artwork row, 8 pt, and the 32 pt scrubber block — takes 100 of it, so 34 and
    /// the 4 above it fill the rest exactly rather than being clipped by four points.
    static let transportRow: CGFloat = 34

    private func player(_ info: NowPlayingInfo) -> some View {
        let accent = Color(nsColor: info.accent)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ArtworkView(image: info.artwork, size: 60, radius: 13, flexible: true)
                    .id(info.artworkID)
                    .transition(IslandMotion.pop(scale: 0.85))
                    .islandMatched(IslandMatchedID.nowPlayingArtwork)
                    .shadow(color: accent.opacity(0.35), radius: 12, y: 4)
                    .onTapGesture { service.openApp() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Open \(info.appName)")
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: info.title.isEmpty ? "Unknown track" : info.title,
                                font: .system(size: 15, weight: .semibold), color: .white)
                    MarqueeText(text: info.artist.isEmpty ? info.appName : info.artist,
                                font: .system(size: 13, weight: .regular), color: .white.opacity(0.55))
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

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let position = info.position(at: context.date)
                let duration = info.duration
                VStack(spacing: 4) {
                    ScrubberView(progress: duration > 0 ? position / duration : 0) { fraction in
                        service.seek(to: fraction * duration)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(IslandAccessibility.playbackValue(position: position, duration: duration))
                    ZStack {
                        HStack {
                            Text(position.mmss)
                            Spacer()
                            Text(duration > 0 ? "-" + max(0, duration - position).mmss : "")
                        }
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                        .opacity(lyricLine == nil ? 1 : 0)
                        if prefs.lyricsEnabled {
                            LyricsView(font: .system(size: 12, weight: .semibold), color: .white.opacity(0.85), lineHeight: 14)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 14)
                }
            }
            .padding(.top, 8)

            // One size and one weight for all three, the way the phone's island sets them.
            // A 30 pt `pause.fill` beside 22 pt triangles is a third again as much ink in the
            // middle of the row: the two skips read as faint and the row lost its centre.
            HStack(spacing: 30) {
                GlyphButton(symbol: "backward.fill", size: Self.transportGlyph, weight: .medium) { service.previous() }
                GlyphButton(symbol: info.isPlaying ? "pause.fill" : "play.fill",
                            size: Self.transportGlyph, weight: .medium) { service.togglePlayPause() }
                    .animation(IslandMotion.fade, value: info.isPlaying)
                GlyphButton(symbol: "forward.fill", size: Self.transportGlyph, weight: .medium) { service.next() }
            }
            .frame(height: Self.transportRow)
            .padding(.top, 4)
        }
        .background(alignment: .top) { backdrop(info) }
    }

    /// The cover, blurred out into the black behind the section — the wash of colour the phone
    /// puts behind what is playing. It fades away to the right so nothing sits behind the
    /// title, and it is only ever as strong as a hint: the island is black first.
    @ViewBuilder
    private func backdrop(_ info: NowPlayingInfo) -> some View {
        if let artwork = info.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: IslandLayout.panelContentWidth, height: IslandLayout.sectionHeight)
                .blur(radius: 40)
                .opacity(0.26)
                // Across the whole width, not a band down the left. Masked to a third of its
                // strength by the halfway mark, the wash ended in a visible edge under the
                // title — a rendering seam rather than a colour. The phone tints the whole
                // card and trusts white text to carry over it, which at this blur and this
                // opacity it does.
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                                           .init(color: .black, location: 0.55),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .offset(y: -6)
                .id(info.artworkID)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var lyricLine: String? {
        guard prefs.lyricsEnabled, let line = lyrics.currentLine?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
        return line
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
