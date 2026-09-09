import SwiftUI

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 3
    var tint: Color = .white
    /// How the ring travels to a new value. A timer's arrives on a one-second clock, and
    /// sweeping for exactly that long is what makes a ring redrawn once a second read as one
    /// that never stops moving — but a download's arrives whenever the poll happens to be,
    /// and a live activity's whenever it is pushed, and for those a spring that lands is
    /// right. Linear everywhere would leave those two permanently a second behind.
    var animation: Animation = IslandMotion.control

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(animation, value: progress)
    }
}
