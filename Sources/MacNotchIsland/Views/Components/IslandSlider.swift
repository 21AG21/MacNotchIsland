import SwiftUI

/// A slim capsule slider for the control rail: 4 pt at rest, 6 pt under the pointer, drag or
/// click anywhere on it. The value is written on every change and the caller decides what
/// that means (volume, brightness).
struct IslandSlider: View {
    var value: Double
    var onChange: (Double) -> Void

    @State private var hovering = false
    @State private var dragging: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let shown = min(1, max(0, dragging ?? value))
            let active = hovering || dragging != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(Color.white.opacity(active ? 0.95 : 0.85))
                    .frame(width: max(0, geo.size.width * shown))
            }
            .frame(height: active ? 6 : 4)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let v = min(1, max(0, drag.location.x / max(1, geo.size.width)))
                        dragging = v
                        onChange(v)
                    }
                    .onEnded { drag in
                        let v = min(1, max(0, drag.location.x / max(1, geo.size.width)))
                        dragging = nil
                        onChange(v)
                    }
            )
            .animation(IslandMotion.quick, value: active)
        }
        .frame(height: 20)
        .onHover { hovering = $0 }
    }
}
