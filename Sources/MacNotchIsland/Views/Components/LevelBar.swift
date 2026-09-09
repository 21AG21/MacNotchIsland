import SwiftUI

struct LevelBar: View {
    var level: Double
    var tint: Color = .white
    /// How the bar moves to a new level. A volume HUD's bar answers a keypress, so it springs
    /// after it; a download's arrives on a clock, so it sweeps at the rate the next one will.
    var animation: Animation = IslandMotion.control

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule().fill(tint.opacity(0.9)).frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, level)))))
            }
        }
        .animation(animation, value: level)
    }
}
