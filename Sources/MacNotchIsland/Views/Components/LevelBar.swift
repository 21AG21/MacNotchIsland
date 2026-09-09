import SwiftUI

/// A level, as a filled capsule.
///
/// Every bar in the app answers something that has just happened — a key, a poll that landed,
/// a push — rather than a clock that can be swept along with, so they all take the same short
/// spring. The ring is the one that has a clock, and it says so itself.
struct LevelBar: View {
    var level: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule().fill(tint.opacity(0.9)).frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, level)))))
            }
        }
        .animation(IslandMotion.control, value: level)
    }
}
