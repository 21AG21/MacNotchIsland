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
            // every marquee Apple ships — Now Playing, the Music app's ticker — fades.
            //
            // On at both ends for as long as the title is a scrolling one, and off entirely
            // when it is not. Tying the leading fade to how far the text had travelled only
            // moved the pop: the cycle ends with the second copy exactly where the first
            // began, so at the wrap the first letters snapped from faded to solid in one
            // frame. A fade that never changes costs the first letter a little contrast
            // during the pause and is worth it — and, not varying with the phase, it belongs
            // out here where it is built once rather than on every frame of the scroll.
            .mask(alignment: .leading) {
                Self.edgeFade(across: geo.size.width, faded: scrolling)
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

    /// Opaque through the middle and clear at both ends, in whatever proportion `fadeWidth`
    /// is of the room there is — clamped, so a slot as narrow as the pill's sneak peek keeps
    /// most of itself readable rather than becoming mostly gradient. Not faded at all, every
    /// stop is opaque and this is a plain rectangle.
    private static func edgeFade(across width: CGFloat, faded: Bool) -> LinearGradient {
        let inset = faded ? min(0.2, fadeWidth / max(width, 1)) : 0
        return LinearGradient(stops: [
            .init(color: .black.opacity(faded ? 0 : 1), location: 0),
            .init(color: .black, location: inset),
            .init(color: .black, location: 1 - inset),
            .init(color: .black.opacity(faded ? 0 : 1), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private var lineHeight: CGFloat { 20 }
}
