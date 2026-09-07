import SwiftUI

/// Single-line text that scrolls sideways when it doesn't fit, like the iPhone's Now Playing.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var speed: Double = 28       // points per second
    var pause: Double = 1.6      // seconds before scrolling starts
    var gap: CGFloat = 36

    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            let distance = Double(textWidth + gap)
            TimelineView(.animation(paused: !overflow)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let cycle = distance / speed + pause
                let phase = t.truncatingRemainder(dividingBy: cycle)
                let offset = overflow ? (phase < pause ? 0 : min(distance, (phase - pause) * speed)) : 0
                HStack(spacing: gap) {
                    label
                    if overflow { label }
                }
                .offset(x: -CGFloat(offset))
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
        }
        .frame(height: lineHeight)
        .background(
            label.fixedSize().hidden().background(
                GeometryReader { g in
                    Color.clear.onChange(of: g.size.width, initial: true) { _, w in textWidth = w }
                }
            )
        )
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private var lineHeight: CGFloat { 20 }
}
