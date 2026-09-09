import SwiftUI

/// Single-line text that scrolls sideways when it doesn't fit, like the iPhone's Now Playing.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var speed: Double = 28       // points per second
    var pause: Double = 1.6      // seconds before scrolling starts
    var gap: CGFloat = 36

    @ObservedObject private var energy = EnergyPolicy.shared
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            // Energy policy can pause scrolling even when the text doesn't fit; show the
            // truncated first copy instead, exactly like the "fits already" case.
            let scrolling = overflow && !energy.animationsPaused
            let distance = Double(textWidth + gap)
            TimelineView(.animation(minimumInterval: energy.animationInterval, paused: !scrolling)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let cycle = distance / speed + pause
                let phase = t.truncatingRemainder(dividingBy: cycle)
                let offset = scrolling ? (phase < pause ? 0 : min(distance, (phase - pause) * speed)) : 0
                HStack(spacing: gap) {
                    label
                    if scrolling { label }
                }
                .offset(x: -CGFloat(offset))
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            // A title that is moving dissolves at the edges rather than being cut off at
            // them: a hard edge makes the letters look like they are hitting a wall, and
            // every marquee Apple ships — Now Playing, the Music app's ticker — fades. Only
            // while it is scrolling: a title that fits is not going anywhere and should not
            // have its first and last letters dimmed for nothing.
            .mask(alignment: .leading) {
                if scrolling {
                    Self.edgeFade(across: geo.size.width)
                } else {
                    Rectangle()
                }
            }
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

    /// How much of each end the fade covers.
    private static let fadeWidth: CGFloat = 12

    /// Opaque through the middle, clear at both ends, in whatever proportion `fadeWidth` is
    /// of the room there is — clamped so a very narrow slot fades rather than disappears.
    private static func edgeFade(across width: CGFloat) -> some View {
        let inset = min(0.35, fadeWidth / max(width, 1))
        return LinearGradient(stops: [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black, location: inset),
            .init(color: .black, location: 1 - inset),
            .init(color: .black.opacity(0), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private var lineHeight: CGFloat { 20 }
}
