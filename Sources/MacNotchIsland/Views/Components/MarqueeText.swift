import SwiftUI

/// Single-line text that scrolls sideways when it doesn't fit, like the iPhone's Now Playing.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var speed: Double = 28       // points per second
    var pause: Double = 1.6      // seconds before scrolling starts
    var gap: CGFloat = 36
    /// Whether what the text names is playing. A paused track's title holds still: it scrolled
    /// on, a frame every thirtieth of a second, for as long as the card showed a track nobody
    /// was listening to — five minutes at a time with "Keep paused music for" as it ships.
    var isPlaying: Bool = true

    @ObservedObject private var energy = EnergyPolicy.shared
    @State private var textWidth: CGFloat = 0
    /// When this text arrived. The scroll is timed from here, so a new title holds still for
    /// its pause and then sets off from its first letter. Timed from the wall clock, as it
    /// was, a new title landed at whatever point of the cycle the clock happened to be at:
    /// most of the time mid-scroll, with its first letters already gone.
    @State private var epoch = Date()

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            // Energy policy can pause scrolling even when the text doesn't fit, and so can the
            // music stopping.
            let scrolling = overflow && isPlaying && !energy.animationsPaused
            let distance = Double(textWidth + gap)
            // A right-to-left title starts at its right-hand end, and scrolls the other way.
            let rightToLeft = overflow && Self.isRightToLeft(text)
            TimelineView(.animation(minimumInterval: energy.animationInterval, paused: !scrolling)) { context in
                let t = max(0, context.date.timeIntervalSince(epoch))
                let cycle = distance / speed + pause
                let phase = t.truncatingRemainder(dividingBy: cycle)
                let offset = scrolling ? (phase < pause ? 0 : min(distance, (phase - pause) * speed)) : 0
                HStack(spacing: gap) {
                    if overflow && !scrolling {
                        // Held still, a title that does not fit ends in an ellipsis. The
                        // full-length label stood here, cut off square at the slot's edge
                        // mid-letter with no fade — in the pill, on the curve of its end.
                        Text(text).font(font).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
                    } else {
                        // The copy that follows comes in from the side the words go towards:
                        // the right for a left-to-right title, the left for a right-to-left one.
                        if scrolling && rightToLeft { label }
                        label
                        if scrolling && !rightToLeft { label }
                    }
                }
                .offset(x: rightToLeft ? CGFloat(offset) : -CGFloat(offset))
            }
            // Held at the end the title starts from. Leading-aligned and moved left, a long
            // Hebrew or Arabic title opened on its last words and its beginning scrolled in last.
            .frame(width: geo.size.width, alignment: rightToLeft ? .trailing : .leading)
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
        .onChange(of: text) { _, _ in epoch = Date() }
        // Played again, the title holds for its pause and sets off from its first letter, the
        // way a new one does, rather than jumping to wherever the clock has got to meanwhile.
        .onChange(of: isPlaying) { _, playing in if playing { epoch = Date() } }
        .background(
            label.fixedSize().hidden().background(
                GeometryReader { g in
                    Color.clear.onChange(of: g.size.width, initial: true) { _, w in
                        textWidth = w
                        // The width is known a frame after the text: the cycle starts then.
                        epoch = Date()
                    }
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

    /// Whether `text` reads right to left, by its first strongly directional character — the
    /// rule the Unicode bidirectional algorithm uses for a paragraph's direction. Digits,
    /// punctuation, spaces and symbols say nothing and are passed over; a text with no letter
    /// at all reads left to right. Pure, so it is tested.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200F, 0x061C: return true    // RIGHT-TO-LEFT MARK, ARABIC LETTER MARK
            case 0x200E: return false           // LEFT-TO-RIGHT MARK
            default: break
            }
            guard scalar.properties.isAlphabetic else { continue }
            return rightToLeftScripts.contains { $0.contains(scalar.value) }
        }
        return false
    }

    /// The blocks of the scripts written right to left: Hebrew, Arabic, Syriac, Thaana, N'Ko,
    /// Samaritan, Mandaic and their supplements and presentation forms, and the historic
    /// right-to-left scripts past the Basic Multilingual Plane.
    private static let rightToLeftScripts: [ClosedRange<UInt32>] = [
        0x0590...0x08FF,
        0xFB1D...0xFDFF,
        0xFE70...0xFEFF,
        0x10800...0x10FFF,
        0x1E800...0x1EFFF,
    ]

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private var lineHeight: CGFloat { 20 }
}
