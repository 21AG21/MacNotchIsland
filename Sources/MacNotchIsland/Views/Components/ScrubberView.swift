import SwiftUI

/// Now Playing scrubber. Thin at rest, thickens on hover, drag to seek.
struct ScrubberView: View {
    var progress: Double
    var onSeek: (Double) -> Void

    @State private var hovering = false
    @State private var dragging: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let p = min(1, max(0, dragging ?? progress))
            let active = hovering || dragging != nil
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
                        dragging = min(1, max(0, value.location.x / max(1, geo.size.width)))
                    }
                    .onEnded { value in
                        let v = min(1, max(0, value.location.x / max(1, geo.size.width)))
                        dragging = nil
                        onSeek(v)
                    }
            )
            .animation(IslandMotion.quick, value: active)
        }
        .frame(height: 14)
        .onHover { hovering = $0 }
    }
}
