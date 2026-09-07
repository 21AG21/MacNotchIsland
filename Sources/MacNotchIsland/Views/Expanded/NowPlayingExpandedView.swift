import SwiftUI

struct NowPlayingExpandedView: View {
    let info: NowPlayingInfo
    let geometry: NotchGeometry
    @ObservedObject private var service = NowPlayingService.shared

    private var accent: Color { Color(nsColor: info.accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top band: artwork left, visualizer right, either side of the notch.
            HStack(alignment: .top, spacing: 0) {
                ArtworkView(image: info.artwork, size: 60, radius: 12)
                    .id(info.artworkID)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .padding(.top, 12)
                Spacer(minLength: 0)
                VisualizerBars(isPlaying: info.isPlaying, color: accent, barCount: 5, barWidth: 3.5, maxHeight: 22, minHeight: 4)
                    .padding(.top, max(6, (geometry.notchHeight - 22) / 2 + 2))
                    .padding(.trailing, 4)
            }
            .frame(height: max(geometry.notchHeight, 72))

            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: info.title.isEmpty ? "Not Playing" : info.title,
                            font: .system(size: 15, weight: .semibold), color: .white)
                MarqueeText(text: info.artist.isEmpty ? info.appName : info.artist,
                            font: .system(size: 13, weight: .regular), color: .white.opacity(0.62))
            }
            .padding(.top, 4)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let position = info.position(at: context.date)
                let duration = info.duration
                VStack(spacing: 2) {
                    ScrubberView(progress: duration > 0 ? position / duration : 0) { fraction in
                        service.seek(to: fraction * duration)
                    }
                    HStack {
                        Text(position.mmss)
                        Spacer()
                        Text(duration > 0 ? "-" + max(0, duration - position).mmss : "")
                    }
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.top, 8)

            ZStack {
                HStack(spacing: 30) {
                    GlyphButton(symbol: "backward.fill", size: 18) { service.previous() }
                    GlyphButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 26) { service.togglePlayPause() }
                    GlyphButton(symbol: "forward.fill", size: 18) { service.next() }
                }
                HStack {
                    Spacer()
                    GlyphButton(symbol: "airplayaudio", size: 14, tint: .white.opacity(0.7)) { service.openApp() }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
}
