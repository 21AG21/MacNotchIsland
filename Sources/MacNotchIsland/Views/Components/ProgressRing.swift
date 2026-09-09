import SwiftUI

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 3
    var tint: Color = .white
    /// How often a new value arrives, in seconds. The sweep takes exactly that long, so a
    /// ring that is really redrawn once a second reads as one that never stops moving. A
    /// spring here made every tick a small, visible jolt.
    var cadence: Double = 1

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(IslandMotion.meter(cadence: cadence), value: progress)
    }
}
