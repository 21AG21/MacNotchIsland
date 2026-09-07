import SwiftUI

/// Compact state: content sits either side of the notch, exactly like the iPhone's
/// leading / trailing regions around the sensor housing.
struct CompactContentView: View {
    let activity: IslandActivity
    let layout: IslandLayout
    let geometry: NotchGeometry
    @EnvironmentObject private var center: ActivityCenter

    var body: some View {
        HStack(spacing: 0) {
            CompactLeadingView(activity: activity, height: layout.bodyHeight)
                .frame(width: layout.leadingWidth, height: layout.bodyHeight)
            Color.clear.frame(width: geometry.notchWidth, height: layout.bodyHeight)
            HStack(spacing: 0) {
                CompactTrailingView(activity: activity, height: layout.bodyHeight)
                    .frame(width: layout.trailingWidth - layout.privacyWidth, height: layout.bodyHeight)
                if layout.privacyWidth > 0 {
                    PrivacyDots().frame(width: layout.privacyWidth, height: layout.bodyHeight)
                }
            }
            .frame(width: layout.trailingWidth, height: layout.bodyHeight)
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight)
    }
}

struct CompactLeadingView: View {
    let activity: IslandActivity
    let height: CGFloat

    private var iconSize: CGFloat { max(12, height * 0.44) }

    var body: some View {
        ZStack {
            switch activity.content {
            case .nowPlaying(let info):
                ArtworkView(image: info.artwork, size: height - 10, radius: 5)
                    .id(info.artworkID)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .timer(let t):
                Image(systemName: t.isFinished ? "bell.fill" : "timer")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, isActive: t.isFinished)
            case .stopwatch(let s):
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(s.isRunning ? .orange : .white.opacity(0.7))
            case .call:
                Image(systemName: "phone.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.green)
            case .battery(let b):
                BatteryGlyph(percent: b.percent, charging: b.isCharging || b.isPluggedIn, tint: b.tint)
                    .frame(width: 26, height: 12)
            case .bluetooth(let d):
                Image(systemName: d.symbol)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
            case .focus(let f):
                Image(systemName: f.symbol)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(f.isOn ? Color.named(f.tint) : .white.opacity(0.7))
            case .hud(let h):
                Image(systemName: h.symbolName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            case .silent(let s):
                Image(systemName: s.isSilent ? "bell.slash.fill" : "bell.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(s.isSilent ? Color(red: 1, green: 0.27, blue: 0.23) : .white)
                    .symbolEffect(.bounce, value: s.isSilent)
            case .unlock:
                Image(systemName: "lock.open.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: true)
            case .calendar(let c):
                Image(systemName: "calendar")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(Color.named(c.tint))
            case .download(let d):
                Image(systemName: d.isComplete ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(d.isComplete ? Color(red: 0.2, green: 0.84, blue: 0.29) : Color(red: 0.04, green: 0.52, blue: 1))
                    .contentTransition(.symbolEffect(.replace))
            case .custom(let c):
                Image(systemName: c.symbol)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(Color.named(c.tint))
            }
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct CompactTrailingView: View {
    let activity: IslandActivity
    let height: CGFloat

    private var textFont: Font { .system(size: max(11, height * 0.4), weight: .semibold, design: .rounded) }

    var body: some View {
        ZStack {
            switch activity.content {
            case .nowPlaying(let info):
                VisualizerBars(isPlaying: info.isPlaying, color: Color(nsColor: info.accent))
            case .timer(let t):
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(t.isFinished ? "0:00" : t.remaining(at: ctx.date).timerString)
                        .font(textFont.monospacedDigit())
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText(countsDown: true))
                }
            case .stopwatch(let s):
                TimelineView(.periodic(from: .now, by: s.isRunning ? 1 : 3600)) { ctx in
                    Text(s.elapsed(at: ctx.date).mmss)
                        .font(textFont.monospacedDigit())
                        .foregroundStyle(s.isRunning ? .orange : .white.opacity(0.7))
                }
            case .call(let c):
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(ctx.date.timeIntervalSince(c.startedAt).mmss)
                        .font(textFont.monospacedDigit())
                        .foregroundStyle(.green)
                }
            case .battery(let b):
                Text("\(b.percent)%")
                    .font(textFont.monospacedDigit())
                    .foregroundStyle(b.tint)
            case .bluetooth(let d):
                if let p = d.summaryPercent {
                    Text("\(p)%").font(textFont.monospacedDigit()).foregroundStyle(.white)
                } else {
                    Text("Connected").font(textFont).foregroundStyle(.white)
                }
            case .focus(let f):
                Text(f.isOn ? "On" : "Off").font(textFont).foregroundStyle(.white)
            case .hud(let h):
                LevelBar(level: h.isMuted ? 0 : h.level, tint: .white)
                    .frame(width: 62, height: 6)
            case .silent(let s):
                Text(s.isSilent ? "Silent" : "Ring")
                    .font(textFont)
                    .foregroundStyle(s.isSilent ? Color(red: 1, green: 0.27, blue: 0.23) : .white)
            case .unlock:
                Text("Unlocked").font(textFont).foregroundStyle(.white)
            case .calendar(let c):
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(c.relativeStart(at: ctx.date)).font(textFont).foregroundStyle(.white)
                }
            case .download(let d):
                if d.isComplete {
                    Text("Done").font(textFont).foregroundStyle(Color(red: 0.2, green: 0.84, blue: 0.29))
                } else if let p = d.progress {
                    ProgressRing(progress: p, lineWidth: 2.5, tint: Color(red: 0.04, green: 0.52, blue: 1))
                        .frame(width: height * 0.5, height: height * 0.5)
                } else {
                    Text(DownloadState.formatter.string(fromByteCount: d.bytes))
                        .font(textFont.monospacedDigit()).foregroundStyle(.white).lineLimit(1)
                }
            case .custom(let c):
                if let p = c.progress, c.showsRing {
                    ProgressRing(progress: p, lineWidth: 2.5, tint: Color.named(c.tint))
                        .frame(width: height * 0.5, height: height * 0.5)
                } else if let text = c.trailingText {
                    Text(text).font(textFont).foregroundStyle(Color.named(c.tint)).lineLimit(1)
                } else {
                    Image(systemName: "ellipsis").font(textFont).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension BatteryState {
    var tint: Color {
        if event == .low || event == .critical || (percent <= 20 && !isPluggedIn) { return Color(red: 1, green: 0.27, blue: 0.23) }
        if isCharging || isPluggedIn || event == .full { return Color(red: 0.2, green: 0.84, blue: 0.29) }
        return .white
    }

    var title: String {
        switch event {
        case .pluggedIn: return isCharging ? "Charging" : "Plugged In"
        case .unplugged: return "On Battery"
        case .low: return "Low Battery"
        case .critical: return "Very Low Battery"
        case .full: return "Charged"
        }
    }
}

extension LevelHUD {
    var symbolName: String {
        switch kind {
        case .brightness:
            return level < 0.05 ? "sun.min" : (level < 0.5 ? "sun.min.fill" : "sun.max.fill")
        case .volume:
            if isMuted || level <= 0.001 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    var title: String { kind == .volume ? (isMuted ? "Muted" : "Volume") : "Brightness" }
}

extension CalendarState {
    func relativeStart(at date: Date) -> String {
        let delta = start.timeIntervalSince(date)
        if delta <= 0 { return end.timeIntervalSince(date) > 0 ? "Now" : "Ended" }
        let m = Int((delta / 60).rounded(.up))
        return m < 60 ? "in \(m)m" : "in \(m / 60)h"
    }
}
