import SwiftUI

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
        .animation(IslandMotion.quick, value: level)
    }
}
