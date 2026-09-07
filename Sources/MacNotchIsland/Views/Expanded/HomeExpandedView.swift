import SwiftUI

/// Shown when the island is idle and hovered: Now Playing mini-player, timer presets,
/// and the file shelf. The Mac's equivalent of long-pressing an empty island.
struct HomeExpandedView: View {
    let geometry: NotchGeometry
    let layout: IslandLayout
    @ObservedObject private var music = NowPlayingService.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 10)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    miniPlayer
                    timerRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if prefs.shelfEnabled {
                    ShelfStripView(isDropTarget: false)
                        .frame(width: 200)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if let info = music.info {
            HStack(spacing: 12) {
                ArtworkView(image: info.artwork, size: 44, radius: 9)
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: info.title, font: .system(size: 13, weight: .semibold), color: .white)
                    MarqueeText(text: info.artist, font: .system(size: 11), color: .white.opacity(0.6))
                }
                GlyphButton(symbol: "backward.fill", size: 13) { music.previous() }
                GlyphButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 18) { music.togglePlayPause() }
                GlyphButton(symbol: "forward.fill", size: 13) { music.next() }
            }
        } else {
            HStack(spacing: 12) {
                ArtworkView(image: nil, size: 44, radius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing playing").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Play something in Music, Spotify or Safari").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var timerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            ForEach([1, 5, 10, 25], id: \.self) { minutes in
                PillButton(title: "\(minutes)m", tint: .orange) {
                    IslandTimer.shared.start(seconds: TimeInterval(minutes * 60), label: "Timer")
                }
            }
            if IslandTimer.shared.state != nil {
                PillButton(title: "Cancel", tint: .white.opacity(0.85)) { IslandTimer.shared.cancel() }
            }
        }
    }
}
