import SwiftUI

/// Compact state: content sits either side of the notch, exactly like the iPhone's
/// leading / trailing regions around the sensor housing.
struct CompactContentView: View {
    let activity: IslandActivity
    let layout: IslandLayout
    @EnvironmentObject private var center: ActivityCenter

    /// The live activity a key-press HUD is drawn over, whose glyph keeps the leading slot.
    private var under: IslandActivity? { IslandLayout.activityUnder(activity, center: center) }

    var body: some View {
        HStack(spacing: 0) {
            // A side the menu bar left no room on (`MenuBarClearance.fitted` gives it 0) is
            // not drawn at all. Drawn into a slot 0 pt wide, a glyph or a word is laid out at
            // its own size around a point on the pill's edge, and half of "Connected" showed at
            // the end of the pill with the rest cut off by it.
            Group {
                if Self.drawsSlot(width: layout.leadingWidth) {
                    CompactLeadingView(activity: under ?? activity, height: layout.bodyHeight)
                }
            }
            .frame(width: layout.leadingWidth, height: layout.bodyHeight)
            Color.clear.frame(width: layout.middleWidth, height: layout.bodyHeight)
            HStack(spacing: 0) {
                let room = layout.trailingWidth - layout.privacyWidth
                Group {
                    if Self.drawsSlot(width: room) {
                        CompactTrailingView(activity: activity, height: layout.bodyHeight,
                                            minimal: room < activity.content.compactWidths.trailing)
                    }
                }
                .frame(width: room, height: layout.bodyHeight)
                if layout.privacyWidth > 0 {
                    // The dots at their own width, and the rest of the slot between them and
                    // the pill's rounded end — see `IslandLayout.compactPrivacyClearance`.
                    PrivacyDots()
                        .frame(width: IslandLayout.privacyDots, height: layout.bodyHeight)
                        .padding(.trailing, max(0, layout.privacyWidth - IslandLayout.privacyDots))
                }
            }
            .frame(width: layout.trailingWidth, height: layout.bodyHeight)
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight)
        .accessibilityElement(children: .combine)
        .modifier(CompactSpeech(shown: activity.content))
    }

    /// Whether a side of the pill has any room to draw in. Pure, so the rule is tested.
    static func drawsSlot(width: CGFloat) -> Bool { width > 0 }
}

/// The pill's one spoken sentence. A call's also says whether the microphone is muted, which
/// is the one thing about a call worth hearing without opening it — and only a call's pill
/// watches the microphone, so nothing else on the island wakes it.
///
/// Written from inside a timeline, the way the cards write theirs (`TimerExpandedView`): the
/// sentence carries the time left, the time gone or how soon, and the pill's body is not run
/// again when the digits on it change — those are redrawn by the timelines inside it. Written
/// once, at the body's time, VoiceOver read "Timer, 4:59 remaining" minutes after it was so.
/// Content whose sentence does not move with the clock gets a timeline that ticks once an hour.
/// The timeline turns on the beat the figure on the pill turns on (`PillClock`), so the
/// sentence never says a second the digits have already left.
private struct CompactSpeech: ViewModifier {
    let shown: ActivityContent

    @ViewBuilder
    func body(content: Content) -> some View {
        if case .call = shown {
            content.modifier(CallSpeech(shown: shown))
        } else {
            TimelineView(PillClock.schedule(for: shown, every: IslandAccessibility.speechCadence(for: shown) ?? Self.still)) { context in
                content.accessibilityLabel(IslandAccessibility.compactLabel(for: shown, at: context.date))
            }
        }
    }

    /// A timeline's interval for a sentence that does not change: an hour, the way the
    /// stopwatch's paused digits are scheduled.
    static let still: TimeInterval = 3600
}

private struct CallSpeech: ViewModifier {
    let shown: ActivityContent
    @ObservedObject private var mic = MicrophoneControl.shared

    func body(content: Content) -> some View {
        TimelineView(PillClock.schedule(for: shown, every: IslandAccessibility.speechCadence(for: shown) ?? CompactSpeech.still)) { context in
            content.accessibilityLabel(IslandAccessibility.compactLabel(for: shown, at: context.date, micMuted: mic.isMuted))
        }
    }
}

/// The call pill's glyph: the green handset, or — while the microphone is muted — a red
/// microphone with a line through it, since "you are muted" is what a glance at a call
/// most needs to catch.
private struct CallGlyph: View {
    let size: CGFloat
    @ObservedObject private var mic = MicrophoneControl.shared

    var body: some View {
        Image(systemName: mic.isMuted ? "mic.slash.fill" : "phone.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(mic.isMuted ? Color.named("red") : Color.green)
            .contentTransition(.symbolEffect(.replace))
    }
}

struct CompactLeadingView: View {
    let activity: IslandActivity
    let height: CGFloat
    /// Whether the slot ends at the cutout. The alert banner borrows this view for its glyph,
    /// and there is no cutout there to keep clear of: carried into the banner, the notch-side
    /// padding set the glyph further in from the banner's end than the figure at the other end
    /// sits from its own. Off the notch the glyph hangs from the leading edge of its slot, the
    /// banner's padding in from the end, the way the figure hangs from the trailing one.
    var besideNotch: Bool = true

    /// One size for every leading glyph: a 16 pt symbol in a 34 pt slot.
    private var iconSize: CGFloat { max(12, height * 0.48) }

    var body: some View {
        ZStack {
            switch activity.content {
            case .nowPlaying(let info):
                ArtworkView(image: info.artwork, size: height - 10, radius: 5, flexible: true)
                    .id(info.artworkID)
                    .transition(IslandMotion.pop(scale: 0.6))
                    // A cover arrives from the service with no animation in its transaction,
                    // so without a curve here the pop above never ran and the cover cut in.
                    .animation(IslandMotion.fade, value: info.artworkID)
                    // Outside `.id` so a track change swaps the cover without tearing the
                    // element out of the matched group mid-expansion.
                    .islandMatched(IslandMatchedID.nowPlayingArtwork)
            case .timer(let t):
                Image(systemName: t.isAlarm ? "alarm.fill" : (t.isFinished ? "bell.fill" : "timer"))
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.orange)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: t.isFinished)
            case .stopwatch(let s):
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(s.isRunning ? .orange : .white.opacity(0.7))
            case .call:
                CallGlyph(size: iconSize)
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
            case .drive(let d):
                Image(systemName: d.symbol)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(Color.named(d.tint))
                    .contentTransition(.symbolEffect(.replace))
            case .capture(let c):
                // The picture itself where the glyph would be, the way Now Playing puts the
                // cover there: it is the one thing that says which capture this is.
                if let image = c.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: height - 10, height: height - 10)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .transition(IslandMotion.pop(scale: 0.6))
                } else {
                    Image(systemName: c.symbol)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(Color.named("blue"))
                }
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
        .padding(.trailing, besideNotch ? 6 : 0)
        .frame(maxWidth: .infinity, alignment: besideNotch ? .center : .leading)
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
    private var wordFont: Font { .system(size: Self.wordSize, weight: .semibold) }
    /// The size of those words, which a script's own trailing text is measured at too — see
    /// `ActivityContent.customTrailingWidth`.
    static let wordSize: CGFloat = 12.5
    /// What the sneak peek keeps clear of the pill's rounded end. The slot runs to the end of
    /// the body, which is a semicircle as tall as the pill, and a title that ran to the edge
    /// of the slot ran into the curve and under the rim.
    static let peekEndClearance: CGFloat = 12
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
                .padding(.trailing, Self.peekEndClearance)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .nowPlaying(let info):
                VisualizerBars(isPlaying: info.isPlaying, color: Color(nsColor: info.accent.blended(withFraction: 0.3, of: .white) ?? info.accent),
                               barCount: minimal ? 3 : 4, barWidth: 2.5, maxHeight: 12, minHeight: 3)
                    .islandMatched(IslandMatchedID.nowPlayingVisualizer)
            case .timer(let t):
                TimelineView(PillClock.schedule(for: activity.content, every: TimerRing.cadence)) { ctx in
                    if minimal {
                        TimerRing(state: t, date: ctx.date, diameter: height * 0.5)
                    } else {
                        // A ringing alarm shows the time it went off for, not a countdown to it.
                        let remaining = t.alarmAt.map(IslandAlarm.clock)
                            ?? (t.isFinished ? "0:00" : t.remaining(at: ctx.date).timerString)
                        Text(remaining)
                            .font(numeralFont)
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(IslandMotion.digits, value: remaining)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .islandMatched(IslandMatchedID.timerTime)
            case .stopwatch(let s):
                TimelineView(PillClock.schedule(for: activity.content, every: s.isRunning ? 1 : 3600)) { ctx in
                    let elapsed = s.elapsed(at: ctx.date).mmss
                    Text(elapsed)
                        .font(numeralFont)
                        .foregroundStyle(s.isRunning ? .white : .white.opacity(0.55))
                        .contentTransition(.numericText(countsDown: false))
                        .animation(IslandMotion.digits, value: elapsed)
                        .lineLimit(1)
                }
                .islandMatched(IslandMatchedID.stopwatchTime)
            case .call(let c):
                TimelineView(PillClock.schedule(for: activity.content, every: 1)) { ctx in
                    let running = ctx.date.timeIntervalSince(c.startedAt).mmss
                    Text(running)
                        .font(numeralFont)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: false))
                        .animation(IslandMotion.digits, value: running)
                        .lineLimit(1)
                }
                .islandMatched(IslandMatchedID.callTime)
            case .battery(let b):
                // The value stays white; only a real warning may be red.
                Text("\(b.percent)%")
                    .font(numeralFont)
                    .foregroundStyle(b.event == .low || b.event == .critical ? Color.named("red") : .white)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(IslandMotion.digits, value: b.percent)
            case .bluetooth(let d):
                if let p = d.summaryPercent {
                    Text("\(p)%").font(numeralFont).foregroundStyle(.white).lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(IslandMotion.digits, value: p)
                } else {
                    Text("Connected").font(wordFont).foregroundStyle(.white).lineLimit(1)
                }
            case .focus(let f):
                Text(f.isOn ? "On" : "Off").font(wordFont).foregroundStyle(.white).lineLimit(1)
            case .hud(let h):
                // The pill is where a key press is actually answered, so the one state a bar
                // cannot express gets said in words rather than shown as an empty bar that
                // reads as silence.
                if h.isUnavailable {
                    Text(minimal ? LevelHUD.readout(h) : LevelHUD.unavailableHint(h))
                        .font(minimal ? numeralFont : wordFont)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    LevelBar(level: h.isMuted ? 0 : h.level, tint: .white)
                        .frame(width: minimal ? 28 : 52, height: 4)
                }
            case .silent(let s):
                Text(s.isSilent ? "Silent" : "Ring")
                    .font(wordFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            case .unlock:
                // Every alert made of words answers with one on this side: "Silent", "On",
                // "Connected". This one answered with nothing, so the island came out of the
                // notch as a single mark at one end of a long black bar with a void after it.
                Text("Unlocked")
                    .font(wordFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            case .calendar(let c):
                TimelineView(PillClock.schedule(for: activity.content, every: 30)) { ctx in
                    Text(c.relativeStart(at: ctx.date)).font(wordFont).foregroundStyle(.white).lineLimit(1)
                }
            case .download(let d):
                if d.isComplete {
                    Text("Done").font(wordFont).foregroundStyle(.white).lineLimit(1)
                } else if let p = d.progress {
                    ProgressRing(progress: p, lineWidth: 2.5, tint: Color.named("blue"))
                        .frame(width: height * 0.5, height: height * 0.5)
                } else {
                    Text(DownloadState.formatter.string(fromByteCount: d.bytes))
                        .font(numeralFont).foregroundStyle(.white).lineLimit(1)
                }
            case .drive(let d):
                Text(d.trailingText).font(d.event == .connected ? numeralFont : wordFont)
                    .foregroundStyle(.white).lineLimit(1)
            case .capture(let c):
                Text(c.trailingText).font(wordFont).foregroundStyle(.white).lineLimit(1)
            case .custom(let c):
                if let p = c.progress, c.showsRing {
                    ProgressRing(progress: p, lineWidth: 2.5, tint: Color.named(c.tint))
                        .frame(width: height * 0.5, height: height * 0.5)
                } else if let since = c.countsUpFrom {
                    // Drawn the way the call's running time is, on the same beat.
                    TimelineView(PillClock.schedule(for: activity.content, every: 1)) { ctx in
                        let running = ctx.date.timeIntervalSince(since).mmss
                        Text(running)
                            .font(numeralFont)
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: false))
                            .animation(IslandMotion.digits, value: running)
                            .lineLimit(1)
                    }
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
                    .animation(IslandMotion.digits, value: s.count)
            }
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// When the pill's running figures turn over, so that the timelines drawing them tick then.
///
/// Every timeline on the pill used to count its beats from the moment the pill appeared
/// (`.periodic(from: .now, …)`), which is a moment that has nothing to do with the figure: a
/// countdown that turns over at 0.3 s past each second was redrawn at 0.9 s past it, and read
/// "4:59" for most of a second after the timer itself was at 4:58 — while the card it opens
/// into, counting from its own appearance, could already say 4:58. Each beat is counted instead
/// from the moment the figure is counted from — the end of a timer, the start of a call or a
/// meeting — so the pill redraws just as its digits change, and the spoken sentence with them.
/// Pure, so the rule is tested.
enum PillClock {
    /// How far past the turn each beat lands. A timeline's date is the beat's own, and a beat
    /// exactly on the turn could come out a hair before it once the arithmetic is done: a timer
    /// at 299.0000001 seconds rounds up to "5:00" and would say it for the whole second. A
    /// hundredth of a second is far more than that error and far less than an eye can see.
    static let lead: TimeInterval = 0.01

    /// The moment the figure on `content` counts from or down to, or nil for content whose
    /// figure is standing still or does not move with the clock at all.
    static func origin(of content: ActivityContent) -> Date? {
        switch content {
        case .timer(let t):
            return t.isAlarm || t.isFinished || t.isPaused ? nil : t.endDate
        case .stopwatch(let s):
            // Where a stopwatch started with nothing on it would have to have started.
            return s.isRunning && s.accumulated.isFinite ? s.startedAt.addingTimeInterval(-s.accumulated) : nil
        case .call(let c):
            return c.startedAt
        case .calendar(let c):
            return c.start
        case .custom(let c):
            return c.countsUpFrom
        default:
            return nil
        }
    }

    /// Where a timeline ticking every `interval` should start from: the last beat at or before
    /// `now` on the grid through `origin`, `lead` past its turn. Always in the past, so nothing
    /// rests on how a schedule that starts in the future would be treated, and `now` itself
    /// when there is no origin to keep time with.
    static func start(on origin: Date?, every interval: TimeInterval, at now: Date) -> Date {
        guard let origin, interval > 0, interval.isFinite else { return now }
        let since = now.timeIntervalSince(origin) - lead
        // Past a few thousand years a Date has no hundredths left to land on.
        guard since.isFinite, abs(since) < 1e11 else { return now }
        let beats = (since / interval).rounded(.down)
        return origin.addingTimeInterval(beats * interval + lead)
    }

    /// The periodic schedule for a timeline on the pill drawing `content`.
    static func schedule(for content: ActivityContent, every interval: TimeInterval,
                         at now: Date = Date()) -> PeriodicTimelineSchedule {
        PeriodicTimelineSchedule(from: start(on: origin(of: content), every: interval, at: now), by: interval)
    }
}

/// Spoken descriptions for island content.
///
/// The compact pill is a pile of tiny glyphs and monospaced digits, so it is combined into a
/// single accessibility element and given a sentence a screen reader can actually read out.
enum IslandAccessibility {
    /// e.g. "Now Playing, Alright by Kendrick Lamar", "Timer, 4 minutes 59 seconds remaining",
    /// "Call with FaceTime, 2 minutes 10 seconds". `micMuted` is read only for a call, which
    /// then ends "microphone muted" — the red glyph on the pill, said out loud.
    ///
    /// Every running figure is said the way the cards say theirs (`spokenDuration`), not in the
    /// pill's clock digits: "4:59" is read as a time of day, and the pill and the card it
    /// opens into described one timer two ways.
    static func compactLabel(for content: ActivityContent, at date: Date = Date(), micMuted: Bool = false) -> String {
        switch content {
        case .nowPlaying(let info):
            let title = info.title.isEmpty ? "Not Playing" : info.title
            if info.artist.isEmpty { return "Now Playing, \(title)" }
            return "Now Playing, \(title) by \(info.artist)"

        case .timer(let t):
            if let alarmAt = t.alarmAt { return "\(t.label), \(IslandAlarm.clock(alarmAt))" }
            if t.isFinished { return "Timer, done" }
            // Rounded up, as the pill's figure is (`timerString`): the second on the digits.
            let remaining = spokenDuration(t.remaining(at: date).rounded(.up))
            return t.isPaused ? "Timer, \(remaining) remaining, paused" : "Timer, \(remaining) remaining"

        case .stopwatch(let s):
            let elapsed = spokenDuration(s.elapsed(at: date))
            return s.isRunning ? "Stopwatch, \(elapsed) elapsed" : "Stopwatch, \(elapsed) elapsed, paused"

        case .call(let c):
            let call = "Call with \(c.appName), \(spokenDuration(date.timeIntervalSince(c.startedAt)))"
            return micMuted ? call + ", microphone muted" : call

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
            if h.isUnavailable {
                // Brightness reaches this too, on a display that answers what it is set to
                // and then refuses to be set.
                let what = h.kind == .volume ? "Volume" : "Brightness"
                return "\(what) is not set here" + (h.device.map { ", \($0)" } ?? "")
            }
            if h.kind == .volume && h.isMuted { return "Volume muted" }
            let where_ = h.device.map { ", \($0)" } ?? ""
            return "\(h.title), \(percent(h.level)) percent\(where_)"

        case .silent(let s):
            return s.isSilent ? "Silent mode on" : "Silent mode off"

        case .unlock:
            return "Mac unlocked"

        case .calendar(let c):
            return "\(c.title), \(c.spokenStart(at: date))"

        case .download(let d):
            if d.isComplete { return "\(d.name) downloaded" }
            if let p = d.progress { return "Downloading \(d.name), \(percent(p)) percent" }
            return "Downloading \(d.name)"

        case .drive(let d):
            return "\(d.name), \(d.subtitle)"

        case .capture(let c):
            return "\(c.title), \(c.name)"

        case .custom(let c):
            // A running clock is what the pill shows, so it is what is said.
            if let since = c.countsUpFrom { return "\(c.title), \(spokenDuration(date.timeIntervalSince(since)))" }
            if let sub = c.subtitle ?? c.trailingText, !sub.isEmpty { return "\(c.title), \(sub)" }
            return c.title

        case .shelf(let s):
            return s.count == 1 ? "Shelf, 1 item" : "Shelf, \(s.count) items"
        }
    }

    /// How often the pill's spoken sentence (`compactLabel`) changes on its own, as the clock
    /// runs: every second where it carries a running figure in minutes and seconds, every half
    /// minute for a meeting's "in 7m" — the beat the pill's own figure is redrawn on — and nil
    /// where nothing in it moves with the clock. Pure, so the rule is tested.
    static func speechCadence(for content: ActivityContent) -> TimeInterval? {
        switch content {
        case .timer(let t):
            return t.isAlarm || t.isFinished || t.isPaused ? nil : TimerRing.cadence
        case .stopwatch(let s):
            return s.isRunning ? 1 : nil
        case .call:
            return 1
        case .calendar:
            return 30
        case .custom(let c):
            return c.countsUpFrom == nil ? nil : 1
        default:
            return nil
        }
    }

    /// "1 minute 5 seconds of 3 minutes 20 seconds" — the scrubber's spoken value, for the
    /// "1:05" and "3:20" either end of it. Just the position for a track with no length to be
    /// a share of, which is also what a live stream's infinite one is.
    static func playbackValue(position: TimeInterval, duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return spokenDuration(position) }
        return "\(spokenDuration(position)) of \(spokenDuration(duration))"
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((max(0, min(1, fraction)) * 100).rounded())
    }
}

extension BatteryState {
    var tint: Color {
        if event == .low || event == .critical || (percent <= 20 && !isPluggedIn) { return Color.named("red") }
        if isCharging || isPluggedIn || event == .full || event == .charged { return Color.named("green") }
        return .white
    }

    var title: String {
        switch event {
        case .pluggedIn: return isCharging ? "Charging" : "Plugged In"
        case .unplugged: return "On Battery"
        case .low: return "Low Battery"
        case .critical: return "Very Low Battery"
        case .full: return "Charged"
        // Named after what to do about it, not after the number: the number is beside it.
        case .charged: return "Enough Charge"
        }
    }
}

extension LevelHUD {
    var symbolName: String {
        switch kind {
        case .brightness:
            // A display that will not be set is not a display turned all the way down, and
            // must not borrow the glyph that says so — the same misreading the volume branch
            // below avoids. A plain sun says "brightness" and nothing about a level; the em
            // dash beside it is what says there is no number.
            if isUnavailable { return "sun.max" }
            return level < 0.05 ? "sun.min" : (level < 0.5 ? "sun.min.fill" : "sun.max.fill")
        case .volume:
            // An output that carries its own level is not a muted Mac, and must not be drawn
            // as one: it is named where it can be named, and where it cannot — a device that
            // has not said what it is called yet — it is still sound going somewhere, so it
            // keeps a speaker rather than borrowing mute's slash. The em dash beside it is
            // what says there is no number.
            if isUnavailable { return deviceSymbol ?? "speaker.wave.2.fill" }
            if isMuted || level <= 0.001 { return "speaker.slash.fill" }
            // Where the sound is going, when that is somewhere worth saying. The bar beside
            // it already carries the level, so the glyph is free to carry the better fact,
            // and it costs no width at all — which is why the system's bezel cannot do it.
            if let deviceSymbol { return deviceSymbol }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .keyboard:
            // The keyboard with its light off, then the lamp at the level it is at.
            if isUnavailable || level <= 0.001 { return "keyboard" }
            return level < 0.5 ? "light.min" : "light.max"
        }
    }

    var title: String { kind == .volume ? (isMuted ? "Muted" : "Volume") : kindName }

    /// What the display is *of*, for somewhere with room to say it: where the sound is going
    /// when that is worth saying, and otherwise what is being set. Never the state — the
    /// figure beside it already carries that, and a row that says "Muted" twice has spent the
    /// one line it had on the half the user could already see.
    var label: String { device ?? kindName }
}

extension CalendarState {
    /// The compact pill's "in 7m", spelled out for a card: "in 7 min", "in 2 hr", "Now".
    func countdown(at date: Date) -> String {
        let delta = start.timeIntervalSince(date)
        guard delta > 0 else { return end.timeIntervalSince(date) > 0 ? "Now" : "Ended" }
        let minutes = Int((delta / 60).rounded(.up))
        return minutes < 60 ? "in \(minutes) min" : "in \(minutes / 60) hr"
    }

    /// The pill's "in 7m", "in 2h", "Now" or "Ended".
    func relativeStart(at date: Date) -> String {
        guard let m = minutesToStart(at: date) else { return end.timeIntervalSince(date) > 0 ? "Now" : "Ended" }
        return m < 60 ? "in \(m)m" : "in \(m / 60)h"
    }

    /// The pill's figure in words, for VoiceOver: "in 7 minutes", "in 1 hour", "now", "ended".
    /// The same figure, whole hours rounded down as the pill has them; read as drawn, "in 7m"
    /// was "in 7 metres".
    func spokenStart(at date: Date) -> String {
        guard let m = minutesToStart(at: date) else { return end.timeIntervalSince(date) > 0 ? "now" : "ended" }
        if m < 60 { return m == 1 ? "in 1 minute" : "in \(m) minutes" }
        let hours = m / 60
        return hours == 1 ? "in 1 hour" : "in \(hours) hours"
    }

    /// Whole minutes until the start, rounded up, or nil once it has begun. Held to a hundred
    /// years before it becomes an `Int`, so a start date nobody could mean does not trap.
    private func minutesToStart(at date: Date) -> Int? {
        let delta = start.timeIntervalSince(date)
        guard delta > 0 else { return nil }
        return Int((min(delta, 3_155_760_000) / 60).rounded(.up))
    }
}
