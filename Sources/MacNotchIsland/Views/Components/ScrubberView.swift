import SwiftUI

/// Now Playing scrubber. Thin at rest, thickens on hover, drag to seek.
///
/// The playhead the user dragged to is held until the player reports it back (see
/// `IslandSlider`, which holds a value the same way): a seek takes a moment to round-trip,
/// and letting go would otherwise snap the bar back to where the track was a second ago.
///
/// Switched off with `.disabled`, as it is for a stream with no length (see
/// `NowPlayingInfo.canSeek`), it is a line and nothing more: it does not thicken under the
/// pointer, which is the scrubber saying it can be dragged, and a click or a drag goes
/// nowhere.
struct ScrubberView: View {
    var progress: Double
    var onSeek: (Double) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var dragging: Double? = nil
    @State private var held: Double?
    @State private var releaseWork: DispatchWorkItem?

    /// Longer than a slider's: a seek goes out to the player and the position comes back on
    /// the next report, which can be a beat later.
    static let settleWindow: TimeInterval = 1.5
    /// Within a second or so of a three-minute track: the player is where it was asked to go.
    static let agreement: Double = 0.03

    var body: some View {
        GeometryReader { geo in
            let p = min(1, max(0, dragging ?? held ?? progress))
            let active = isEnabled && (hovering || dragging != nil)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Color.white.opacity(active ? 1 : 0.85))
                    .frame(width: max(0, geo.size.width * p))
            }
            .frame(height: active ? 9 : 6)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        if dragging == nil {
                            releaseWork?.cancel()
                            releaseWork = nil
                            ActivityCenter.shared.setControlDragging(true)
                        }
                        dragging = fraction(of: value.location.x, in: geo.size.width)
                    }
                    .onEnded { value in
                        let v = fraction(of: value.location.x, in: geo.size.width)
                        // A drag that began is let go of whatever happens; only a scrubber
                        // that is still switched on goes on to seek.
                        if dragging != nil { ActivityCenter.shared.setControlDragging(false) }
                        dragging = nil
                        guard isEnabled else { return }
                        held = v
                        onSeek(v)
                        let work = DispatchWorkItem { self.held = nil }
                        releaseWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleWindow, execute: work)
                    }
            )
            .animation(IslandMotion.control, value: active)
            .onChange(of: progress) { _, new in
                guard dragging == nil, let held, abs(new - held) < Self.agreement else { return }
                self.held = nil
                releaseWork?.cancel()
                releaseWork = nil
            }
            // Switched off under the pointer — the next track is a stream — lets go of a drag
            // and of a playhead held for a seek that is not coming back.
            .onChange(of: isEnabled) { _, enabled in
                guard !enabled else { return }
                if dragging != nil { ActivityCenter.shared.setControlDragging(false) }
                dragging = nil
                held = nil
                releaseWork?.cancel()
                releaseWork = nil
            }
        }
        .frame(height: 14)
        .onHover { hovering = $0 }
        .onDisappear {
            releaseWork?.cancel()
            releaseWork = nil
            if dragging != nil { ActivityCenter.shared.setControlDragging(false) }
            dragging = nil
            held = nil
        }
    }

    private func fraction(of x: CGFloat, in width: CGFloat) -> Double {
        min(1, max(0, Double(x / max(1, width))))
    }
}
