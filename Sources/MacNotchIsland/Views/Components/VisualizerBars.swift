import SwiftUI

/// The iPhone's animated audio bars, tinted from the album artwork.
struct VisualizerBars: View {
    var isPlaying: Bool
    var color: Color
    var barCount: Int = 4
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 14
    var minHeight: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth * 0.8) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: height(index: index, time: t))
                }
            }
            .animation(.easeOut(duration: 0.25), value: isPlaying)
        }
        .frame(height: maxHeight)
    }

    private func height(index: Int, time t: Double) -> CGFloat {
        guard isPlaying else { return minHeight }
        let f1 = 2.1 + Double(index) * 0.37
        let f2 = 3.3 + Double(index) * 0.53
        let phase = Double(index) * 1.7
        let v = 0.55 + 0.45 * (0.6 * sin(t * f1 + phase) + 0.4 * sin(t * f2 * 1.3 + phase * 2.1))
        return minHeight + (maxHeight - minHeight) * CGFloat(max(0, min(1, v)))
    }
}
