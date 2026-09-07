import SwiftUI

/// The detached circle shown to the right of the island when a second activity is live
/// (the iPhone's "minimal" presentation). Tap to swap it into the island.
struct BubbleView: View {
    let activity: IslandActivity
    let diameter: CGFloat
    @EnvironmentObject private var center: ActivityCenter

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            glyph
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onTapGesture { center.promote(id: activity.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Second activity: \(kindDescription)")
        .accessibilityHint("Click to swap into the island")
        .accessibilityAction { center.promote(id: activity.id) }
    }

    /// Sentence-case name for the activity this bubble represents, reusing its own title
    /// where it has one rather than inventing new copy.
    private var kindDescription: String {
        switch activity.content {
        case .nowPlaying: return "Now Playing"
        case .timer: return "Timer"
        case .stopwatch: return "Stopwatch"
        case .download: return "Download"
        case .call: return "Call"
        case .calendar(let c): return c.title
        case .custom(let c): return c.title
        default: return "Activity"
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch activity.content {
        case .nowPlaying(let info):
            VisualizerBars(isPlaying: info.isPlaying, color: Color(nsColor: info.accent), barCount: 3, barWidth: 2.5, maxHeight: 12, minHeight: 3)
        case .timer(let t):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                ProgressRing(progress: t.progress(at: ctx.date), lineWidth: 2.5, tint: .orange)
                    .frame(width: diameter * 0.55, height: diameter * 0.55)
                    .overlay(Image(systemName: "timer").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange))
            }
        case .stopwatch(let s):
            Image(systemName: "stopwatch.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(s.isRunning ? .orange : .white.opacity(0.7))
        case .download(let d):
            if let p = d.progress, !d.isComplete {
                ProgressRing(progress: p, lineWidth: 2.5, tint: Color(red: 0.04, green: 0.52, blue: 1))
                    .frame(width: diameter * 0.55, height: diameter * 0.55)
            } else {
                Image(systemName: d.isComplete ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 0.04, green: 0.52, blue: 1))
            }
        case .call:
            Image(systemName: "phone.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
        case .calendar(let c):
            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.named(c.tint))
        case .custom(let c):
            if let p = c.progress, c.showsRing {
                ProgressRing(progress: p, lineWidth: 2.5, tint: Color.named(c.tint))
                    .frame(width: diameter * 0.55, height: diameter * 0.55)
            } else {
                Image(systemName: c.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.named(c.tint))
            }
        default:
            Circle().fill(Color.white.opacity(0.8)).frame(width: 6, height: 6)
        }
    }
}
