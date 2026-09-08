import SwiftUI

/// Compact state: content sits either side of the notch, exactly like the iPhone's
/// leading / trailing regions around the sensor housing.
struct CompactContentView: View {
    let activity: IslandActivity
    let layout: IslandLayout
    let geometry: NotchGeometry
    @EnvironmentObject private var center: ActivityCenter

    /// The live activity a key-press HUD is drawn over, whose glyph keeps the leading slot.
    private var under: IslandActivity? { IslandLayout.activityUnder(activity, center: center) }

    var body: some View {
        HStack(spacing: 0) {
            CompactLeadingView(activity: under ?? activity, height: layout.bodyHeight)
                .frame(width: layout.leadingWidth, height: layout.bodyHeight)
            Color.clear.frame(width: geometry.notchWidth, height: layout.bodyHeight)
            HStack(spacing: 0) {
                CompactTrailingView(activity: activity, height: layout.bodyHeight,
                                    minimal: layout.trailingWidth - layout.privacyWidth < activity.content.compactWidths.trailing)
                    .frame(width: layout.trailingWidth - layout.privacyWidth, height: layout.bodyHeight)
                if layout.privacyWidth > 0 {
                    PrivacyDots().frame(width: layout.privacyWidth, height: layout.bodyHeight)
                }
            }
            .frame(width: layout.trailingWidth, height: layout.bodyHeight)
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(IslandAccessibility.compactLabel(for: activity.content))
    }
}

struct CompactLeadingView: View {
    let activity: IslandActivity
    let height: CGFloat

    /// One size for every leading glyph: a 16 pt symbol in a 34 pt slot.
    private var iconSize: CGFloat { max(12, height * 0.48) }

    var body: some View {
        ZStack {
            switch activity.content {
            case .nowPlaying(let info):
                ArtworkView(image: info.artwork, size: height - 10, radius: 5, flexible: true)
                    .id(info.artworkID)
                    .transition(IslandMotion.pop(scale: 0.6))
                    // Outside `.id` so a track change swaps the cover without tearing the
                    // element out of the matched group mid-expansion.
                    .islandMatched(IslandMatchedID.nowPlayingArtwork)
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
                    .islandMatched(IslandMatchedID.callGlyph)
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
                    .foregroundStyle(s.isSilent ? Color.named("red") : .white)
                    .symbolEffect(.bounce, value: s.isSilent)
            case .unlock:
                Image(systemName: "lock.open.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: true)
            case .calendar:
                Image(systemName: "calendar")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
            case .download(let d):
                Image(systemName: d.isComplete ? "checkmark" : "arrow.down")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(d.isComplete ? Color.named("green") : Color.named("blue"))
                    .contentTransition(.symbolEffect(.replace))
            case .custom(let c):
                Image(systemName: c.symbol)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(Color.named(c.tint))
            case .shelf:
                Image(systemName: "tray.full.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        // Padding on the notch side, so the glyph sits toward the open end of the slot and
        // clear of the cutout's rounded corner.
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct CompactTrailingView: View {
    let activity: IslandActivity
    let height: CGFloat
    /// The menu bar left less room than the full trailing width: show only what still reads
    /// at a glance (bars, a ring, a count) and skip the words.
    var minimal: Bool = false

    /// Words ("Connected", "On", "Unlocked", "in 5m") sit in the system face like every other
    /// label in the island; only numerals get the rounded face and tabular digits, the way
    /// the iPhone sets its countdowns and percentages.
    private var wordFont: Font { .system(size: 12.5, weight: .semibold) }
    private var numeralFont: Font { .system(size: max(11, height * 0.4), weight: .semibold, design: .rounded).monospacedDigit() }

    var body: some View {
        ZStack {
            switch activity.content {
            case .nowPlaying(let info) where activity.id == NowPlayingService.peekAlertID && !minimal:
                // The sneak peek: what just started, for a moment, where the bars go.
                VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(text: info.title, font: .system(size: 12, weight: .semibold), color: .white)
                        .frame(height: 15)
                    MarqueeText(text: info.artist.isEmpty ? info.appName : info.artist,
                                font: .system(size: 11, weight: .regular), color: .white.opacity(0.55))
                        .frame(height: 13)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .nowPlaying(let info):
                VisualizerBars(isPlaying: info.isPlaying, color: Color(nsColor: info.accent.blended(withFraction: 0.3, of: .white) ?? info.accent),
                               barCount: minimal ? 3 : 4, barWidth: 2.5, maxHeight: 12, minHeight: 3)
                    .islandMatched(IslandMatchedID.nowPlayingVisualizer)
            case .timer(let t):
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    if minimal {
                        ProgressRing(progress: t.progress(at: ctx.date), lineWidth: 2.5, tint: .orange)
                            .frame(width: height * 0.5, height: height * 0.5)
                    } else {
                        Text(t.isFinished ? "0:00" : t.remaining(at: ctx.date).timerString)
                            .font(numeralFont)
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                            .lineLimit(1)
                    }
                }
                .islandMatched(IslandMatchedID.timerTime)
            case .stopwatch(let s):
                TimelineView(.periodic(from: .now, by: s.isRunning ? 1 : 3600)) { ctx in
                    Text(s.elapsed(at: ctx.date).mmss)
                        .font(numeralFont)
                        .foregroundStyle(s.isRunning ? .white : .white.opacity(0.55))
                        .contentTransition(.numericText(countsDown: false))
                        .lineLimit(1)
                }
                .islandMatched(IslandMatchedID.stopwatchTime)
            case .call(let c):
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(ctx.date.timeIntervalSince(c.startedAt).mmss)
                        .font(numeralFont)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: false))
                        .lineLimit(1)
                }
                .islandMatched(IslandMatchedID.callTime)
            case .battery(let b):
                // The value stays white; only a real warning may be red.
                Text("\(b.percent)%")
                    .font(numeralFont)
                    .foregroundStyle(b.event == .low || b.event == .critical ? Color.named("red") : .white)
            case .bluetooth(let d):
                if let p = d.summaryPercent {
                    Text("\(p)%").font(numeralFont).foregroundStyle(.white)
                } else {
                    Text("Connected").font(wordFont).foregroundStyle(.white)
                }
            case .focus(let f):
                Text(f.isOn ? "On" : "Off").font(wordFont).foregroundStyle(.white)
            case .hud(let h):
                LevelBar(level: h.isMuted ? 0 : h.level, tint: .white)
                    .frame(width: minimal ? 28 : 52, height: 4)
            case .silent(let s):
                Text(s.isSilent ? "Silent" : "Ring")
                    .font(wordFont)
                    .foregroundStyle(.white)
            case .unlock:
                EmptyView()
            case .calendar(let c):
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(c.relativeStart(at: ctx.date)).font(wordFont).foregroundStyle(.white)
                }
            case .download(let d):
                if d.isComplete {
                    Text("Done").font(wordFont).foregroundStyle(.white)
                } else if let p = d.progress {
                    ProgressRing(progress: p, lineWidth: 2.5, tint: Color.named("blue"))
                        .frame(width: height * 0.5, height: height * 0.5)
                } else {
                    Text(DownloadState.formatter.string(fromByteCount: d.bytes))
                        .font(numeralFont).foregroundStyle(.white).lineLimit(1)
                }
            case .custom(let c):
                if let p = c.progress, c.showsRing {
                    ProgressRing(progress: p, lineWidth: 2.5, tint: Color.named(c.tint))
                        .frame(width: height * 0.5, height: height * 0.5)
                } else if let text = c.trailingText {
                    Text(text).font(wordFont).foregroundStyle(.white).lineLimit(1)
                } else {
                    Image(systemName: "ellipsis").font(wordFont).foregroundStyle(.white.opacity(0.6))
                }
            case .shelf(let s):
                Text("\(s.count)")
                    .font(numeralFont)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(IslandMotion.quick, value: s.count)
            }
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Spoken descriptions for island content.
///
/// The compact pill is a pile of tiny glyphs and monospaced digits, so it is combined into a
/// single accessibility element and given a sentence a screen reader can actually read out.
enum IslandAccessibility {
    /// e.g. "Now Playing, Alright by Kendrick Lamar", "Timer, 4:59 remaining",
    /// "Call with FaceTime, 2:10".
    static func compactLabel(for content: ActivityContent, at date: Date = Date()) -> String {
        switch content {
        case .nowPlaying(let info):
            let title = info.title.isEmpty ? "Not Playing" : info.title
            if info.artist.isEmpty { return "Now Playing, \(title)" }
            return "Now Playing, \(title) by \(info.artist)"

        case .timer(let t):
            if t.isFinished { return "Timer, done" }
            let remaining = t.remaining(at: date).timerString
            return t.isPaused ? "Timer, \(remaining) remaining, paused" : "Timer, \(remaining) remaining"

        case .stopwatch(let s):
            let elapsed = s.elapsed(at: date).mmss
            return s.isRunning ? "Stopwatch, \(elapsed) elapsed" : "Stopwatch, \(elapsed) elapsed, paused"

        case .call(let c):
            return "Call with \(c.appName), \(date.timeIntervalSince(c.startedAt).mmss)"

        case .battery(let b):
            let charging = b.isCharging || b.isPluggedIn
            return charging ? "Battery charging, \(b.percent) percent" : "Battery, \(b.percent) percent"

        case .bluetooth(let d):
            guard d.isConnected else { return "\(d.name) disconnected" }
            if let p = d.summaryPercent { return "\(d.name) connected, \(p) percent battery" }
            return "\(d.name) connected"

        case .focus(let f):
            return f.isOn ? "\(f.name) Focus on" : "\(f.name) Focus off"

        case .hud(let h):
            if h.kind == .volume && h.isMuted { return "Volume muted" }
            return "\(h.title), \(percent(h.level)) percent"

        case .silent(let s):
            return s.isSilent ? "Silent mode on" : "Silent mode off"

        case .unlock:
            return "Mac unlocked"

        case .calendar(let c):
            return "\(c.title), \(c.relativeStart(at: date))"

        case .download(let d):
            if d.isComplete { return "\(d.name) downloaded" }
            if let p = d.progress { return "Downloading \(d.name), \(percent(p)) percent" }
            return "Downloading \(d.name)"

        case .custom(let c):
            if let sub = c.subtitle ?? c.trailingText, !sub.isEmpty { return "\(c.title), \(sub)" }
            return c.title

        case .shelf(let s):
            return s.count == 1 ? "Shelf, 1 item" : "Shelf, \(s.count) items"
        }
    }

    /// "1:05 of 3:20" — the scrubber's spoken value.
    static func playbackValue(position: TimeInterval, duration: TimeInterval) -> String {
        guard duration > 0 else { return position.mmss }
        return "\(position.mmss) of \(duration.mmss)"
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((max(0, min(1, fraction)) * 100).rounded())
    }
}

extension BatteryState {
    var tint: Color {
        if event == .low || event == .critical || (percent <= 20 && !isPluggedIn) { return Color.named("red") }
        if isCharging || isPluggedIn || event == .full { return Color.named("green") }
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
    /// The compact pill's "in 7m", spelled out for a card: "in 7 min", "in 2 hr", "Now".
    func countdown(at date: Date) -> String {
        let delta = start.timeIntervalSince(date)
        guard delta > 0 else { return end.timeIntervalSince(date) > 0 ? "Now" : "Ended" }
        let minutes = Int((delta / 60).rounded(.up))
        return minutes < 60 ? "in \(minutes) min" : "in \(minutes / 60) hr"
    }

    func relativeStart(at date: Date) -> String {
        let delta = start.timeIntervalSince(date)
        if delta <= 0 { return end.timeIntervalSince(date) > 0 ? "Now" : "Ended" }
        let m = Int((delta / 60).rounded(.up))
        return m < 60 ? "in \(m)m" : "in \(m / 60)h"
    }
}
