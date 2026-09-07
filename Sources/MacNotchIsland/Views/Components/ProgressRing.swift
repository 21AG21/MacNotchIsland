import SwiftUI

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 3
    var tint: Color = .white

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(IslandMotion.quick, value: progress)
    }
}
