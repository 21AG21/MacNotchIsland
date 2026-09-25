import AppKit
import Foundation
import SwiftUI

/// Trackpad gestures on the island.
///
/// Every gesture reaches us as a scroll-wheel event on `NotchHostingView`, which only sees
/// events inside the island's footprint (its `hitTest` returns nil everywhere else), so
/// nothing outside the island is affected.
///
/// - A horizontal swipe on the compact Now Playing pill skips tracks; on the open panel it
///   steps to the next or previous view, the way the switcher reads.
/// - A vertical scroll changes the output volume while the island is showing nothing that
///   scrolls by itself — or, with "Open and close" chosen in the Island pane, a swipe down on
///   the closed island opens the panel and a swipe up on the panel closes it.
/// - A vertical scroll on a timer's pill moves the timer a minute at a time instead, and in
///   "Open and close" a swipe that goes far enough still opens the panel — putting back the
///   minutes it moved on its way past a step.
/// - Anything else is handed straight back to SwiftUI, so the lists keep their vertical
///   scroll — the clipboard, Notes, Notifications, Controls' three columns — and a strip with
///   tiles out of sight to the side, the Shelf's or the Windows section's, keeps its sideways
///   one. A strip with nothing hidden still steps.
///
/// The decision is a pure function (`decide`) so it can be tested without AppKit, CoreAudio
/// or a real trackpad. There are no timers anywhere: throttling and cooldowns compare
/// timestamps of events we are being handed anyway, so an idle island costs nothing.
final class GestureRouter {
    static let shared = GestureRouter()

    // MARK: - Pure decision layer

    /// What the island is showing, reduced to the only distinctions gestures care about.
    enum Context: Equatable {
        case idle
        case compactNowPlaying
        /// A timer's pill, while the timer has not rung: a vertical scroll moves its end.
        case compactTimer
        case otherCompact
        /// A system card (an alert with a large view).
        case card
        /// The panel: `index` is the current view's position in the ring of `count` views;
        /// `scrolls` when the section scrolls by itself (a list, a strip); `scrollsSideways`
        /// when what it scrolls is a strip running sideways with tiles out of sight beyond its
        /// edge (`stripOverflows`); `pinned` when it was opened rather than only shown under
        /// the pointer.
        case panel(index: Int, count: Int, scrolls: Bool, scrollsSideways: Bool = false, pinned: Bool = true)
        case shelf
    }

    /// What a bare vertical scroll on the island means — the Island pane's choice, stored as
    /// `Preferences.verticalSwipe`.
    enum VerticalSwipe: String, CaseIterable {
        /// The output volume, as it always was.
        case volume
        /// Down on the closed island opens the panel; up on the panel closes it.
        case openClose

        /// The stored preference, read back. Anything this build does not know is the volume.
        init(preference: String) {
            self = VerticalSwipe(rawValue: preference) ?? .volume
        }
    }

    enum Action: Equatable {
        case nextTrack
        case previousTrack
        case stepView(forward: Bool)
        /// Change in output volume, on the 0...1 scale.
        case volume(delta: Double)
        /// The same, for the display's brightness: what the scroll means with Option held.
        case brightness(delta: Double)
        /// The same, for the keyboard's backlight: what the scroll means with Control held.
        case keyboard(delta: Double)
        /// A swipe down on the closed island (or on a panel only under the pointer): open it.
        case openPanel
        /// A swipe up on the panel: close it.
        case closePanel
        /// Where the timer under the pointer should be, in whole minutes from where it was
        /// when the gesture began: positive is more time. The whole gesture's count, not a
        /// change, so the router applies only what it has not applied yet.
        case nudgeTimer(steps: Int)
        case none
    }

    /// Accumulated horizontal distance, in points, that makes a track skip.
    static let swipeThreshold: CGFloat = 40
    /// A step between views asks for a little more: a scroll with a tilt must not change views.
    static let viewSwipeThreshold: CGFloat = 55
    /// Volume change per point of vertical scrolling.
    static let volumeStep: Double = 0.004
    /// The same for the brightness, which the scroll moves while Option is held. Its own
    /// constant because the two are free to diverge; they simply have not yet.
    static let brightnessStep: Double = 0.004
    /// And for the keyboard's backlight, which the scroll moves while Control is held.
    static let keyboardStep: Double = 0.004
    /// How far a gesture has to travel before it is locked to one axis.
    static let axisLockThreshold: CGFloat = 6
    /// A classic wheel reports lines, not points; this makes one line comparable with a
    /// trackpad's points.
    static let lineScale: CGFloat = 16
    /// A pause this long starts a new gesture (mouse wheels carry no phase information).
    static let gestureGap: TimeInterval = 0.25
    /// At most ~30 volume writes a second.
    static let volumeInterval: TimeInterval = 1.0 / 30.0
    /// Two track skips (or view steps, or a swipe opening or closing the panel) can never be
    /// closer together than this.
    static let trackCooldown: TimeInterval = 0.6
    /// Vertical distance, in points, that makes a swipe open or close the panel with the
    /// sensitivity in the middle. Between a track skip's and a view step's: a swipe that means
    /// it gets there easily, and the few points a hand drifts while resting on the trackpad
    /// never do. See `openCloseThreshold(sensitivity:)` for the distance at other settings.
    static let openCloseDistance: CGFloat = 50
    /// How far the sensitivity slider reaches either way.
    static let sensitivityRange: ClosedRange<Double> = 0.5...2
    /// Vertical distance, in points, per minute a scroll moves a timer. Under the swipe's
    /// threshold, so a small scroll moves the timer before a large one opens the panel.
    static let timerStepDistance: CGFloat = 24

    /// UserDefaults key for the Home section the panel last showed.
    static let homeTabKey = "homeTab"

    /// Whether a horizontal swipe means anything here. On the panel it steps to the next view,
    /// except over a strip with tiles out of sight to the side: two fingers are how anybody
    /// reaches those, and taking the swipe for a step left the Shelf's files and the Windows
    /// section's tiles past the fourth with no way to be scrolled to at all. A strip with
    /// nothing hidden has nothing to scroll, so a Shelf holding two files still steps. Tab,
    /// the arrows and the switcher step from anywhere.
    static func consumesHorizontalSwipes(_ context: Context) -> Bool {
        switch context {
        case .compactNowPlaying: return true
        case .panel(_, let count, _, let sideways, _): return count > 1 && !sideways
        case .idle, .compactTimer, .otherCompact, .card, .shelf: return false
        }
    }

    /// Whether a sideways strip of `count` tiles, `across` of which fit its width, has any out
    /// of sight — the only strip a sideways swipe has anything to scroll on.
    static func stripOverflows(count: Int, across: Int) -> Bool {
        count > across
    }

    /// Whether the island keeps a vertical scroll here, whatever it goes on to do with it. A
    /// section that scrolls keeps its own scroll events, and so does the shelf's strip.
    static func consumesVerticalScroll(_ context: Context) -> Bool {
        switch context {
        case .idle, .compactNowPlaying, .compactTimer, .otherCompact, .card: return true
        case .panel(_, _, let scrolls, _, _): return !scrolls
        case .shelf: return false
        }
    }

    /// How far a swipe has to travel to open or close the panel at a given sensitivity: twice
    /// as sensitive is half as far. Held to the slider's range, whatever was stored.
    static func openCloseThreshold(sensitivity: Double) -> CGFloat {
        let held = min(sensitivityRange.upperBound, max(sensitivityRange.lowerBound, sensitivity))
        return openCloseDistance / CGFloat(held)
    }

    /// What a swipe up closes.
    enum CloseTarget: Equatable {
        /// Whatever is open, through `ActivityCenter.collapse`: the panel on every island it
        /// shows on, and the peek under the pointer.
        case everything
        /// Only the peek on the island the swipe is on.
        case peekHere
    }

    /// A swipe up on a panel that is only peeking, while the panel is pinned on another
    /// display's island, is about this island's peek and nothing else. `collapse` closes the
    /// panel wherever it is, so the swipe closed the one pinned over there, which nobody's
    /// fingers were on. With nothing open, or with the panel open on this island, closing
    /// everything is closing what is under the fingers, and `collapse` is still the way.
    static func closeTarget(openHere: Bool, isOpen: Bool) -> CloseTarget {
        isOpen && !openHere ? .peekHere : .everything
    }

    /// Whole minutes a gesture's vertical travel asks of a timer: up is more time, the way up
    /// is more volume. Counted toward zero, so a scroll shorter than one step moves nothing.
    static func timerSteps(travel: CGFloat) -> Int {
        guard travel.isFinite else { return 0 }
        // Bounded before it becomes an Int, which would trap on a figure no hand can scroll.
        let steps = min(999, max(-999, (-travel / timerStepDistance).rounded(.towardZero)))
        return Int(steps)
    }

    /// What one gesture has done to the timer under it: the minutes it has asked for, and the
    /// seconds the timer actually moved for them — fewer, when taking time off met the timer's
    /// last second (`IslandTimer.adjustment`). Kept so that a swipe which set off as a small
    /// scroll, nudged the timer on its way past a step, and then went far enough to open the
    /// panel can put exactly that back: the swipe was the whole gesture, never a nudge.
    ///
    /// The timer itself is reached through `move`, which moves one by a number of seconds and
    /// answers how far it really went, so the bookkeeping can be tested without a trackpad.
    struct TimerNudge: Equatable {
        typealias Move = (_ id: String, _ seconds: TimeInterval) -> TimeInterval

        /// The timer this gesture has moved, once it has moved one.
        private(set) var id: String?
        /// Whole minutes from where the gesture found the timer: positive is more time.
        private(set) var steps = 0
        /// Seconds the timer has actually moved in this gesture, either way.
        private(set) var moved: TimeInterval = 0

        /// Moves the timer to `steps` minutes from where the gesture found it, applying only
        /// what has not been applied yet. False when there is nothing to do or nothing moved —
        /// a timer that has rung, or one already at its last second — and then the count stays
        /// where it was, so what lands later is still measured from what really happened. A
        /// gesture belongs to the timer it first moved.
        mutating func nudge(id: String, toward steps: Int, move: Move) -> Bool {
            if let current = self.id, current != id { return false }
            guard steps != self.steps else { return false }
            let change = move(id, TimeInterval(steps - self.steps) * IslandTimer.addStep)
            guard change != 0 else { return false }
            self.id = id
            self.steps = steps
            moved += change
            return true
        }

        /// Undoes everything this gesture moved, through `move`, and forgets it. False when it
        /// had moved nothing.
        mutating func putBack(move: Move) -> Bool {
            guard let id = self.id, moved != 0 else { return false }
            _ = move(id, -moved)
            self = TimerNudge()
            return true
        }
    }

    /// The whole gesture policy, as a pure function.
    ///
    /// `dx` is the horizontal distance accumulated so far in the current gesture and `dy` the
    /// vertical distance still to be applied, both as AppKit reports them: with the default
    /// (natural) scroll direction moving the fingers left gives a negative `dx` and moving
    /// them up a negative `dy`. So a swipe to the left advances (next track, next view) and a
    /// swipe up raises the volume. A step past either end of the ring is `.none`: a swipe is
    /// spatial, only Tab wraps.
    ///
    /// `wantsBrightness` is Option held, `wantsKeyboard` Control held; with both, neither is
    /// meant clearly enough to act on, and the scroll stays whatever a bare scroll is. A key
    /// held down names its level outright in either `verticalSwipe` mode.
    ///
    /// `travel` is the vertical distance of the whole gesture so far, which is what a swipe
    /// and a timer's minutes are measured on; the level controls move by `dy`, the part not
    /// applied yet. Left out, it is `dy`: one event that is the whole gesture.
    ///
    /// `swipeFired` is this gesture having already opened or closed the panel. A swipe is the
    /// whole gesture, so nothing after it acts, whatever the island has become under the
    /// fingers: a swipe up that closed the panel onto a running timer's pill went on taking a
    /// minute off the timer for every step the rest of it travelled, with a tap for each.
    ///
    /// With `.openClose`, a swipe down past `openCloseThreshold(sensitivity:)` on the closed
    /// island — idle, a pill, a card, or a panel that is only under the pointer — opens it,
    /// and a swipe up as far on the panel closes it; a bare scroll does nothing else. On a
    /// timer's pill, in either mode, a scroll that has not become a swipe moves the timer a
    /// minute per `timerStepDistance`: a small scroll nudges, a big swipe opens.
    static func decide(dx: CGFloat, dy: CGFloat, context: Context, wantsBrightness: Bool = false,
                       wantsKeyboard: Bool = false, verticalSwipe: VerticalSwipe = .volume,
                       sensitivity: Double = 1, travel: CGFloat? = nil, swipeFired: Bool = false) -> Action {
        guard !swipeFired else { return .none }
        let threshold: CGFloat
        if case .panel = context { threshold = viewSwipeThreshold } else { threshold = swipeThreshold }
        if abs(dx) > threshold, abs(dx) >= abs(dy), consumesHorizontalSwipes(context) {
            let forward = dx < 0
            switch context {
            case .compactNowPlaying:
                return forward ? .nextTrack : .previousTrack
            case .panel(let index, let count, _, _, _):
                let next = index + (forward ? 1 : -1)
                guard next >= 0, next < count else { return .none }
                return .stepView(forward: forward)
            default:
                return .none
            }
        }
        guard consumesVerticalScroll(context) else { return .none }
        let distance = travel ?? dy
        let level = Double(-dy)
        switch (wantsBrightness, wantsKeyboard) {
        case (true, false): return dy == 0 ? .none : .brightness(delta: level * brightnessStep)
        case (false, true): return dy == 0 ? .none : .keyboard(delta: level * keyboardStep)
        default: break
        }
        if verticalSwipe == .openClose {
            let reach = openCloseThreshold(sensitivity: sensitivity)
            if case .panel(_, _, _, _, let pinned) = context {
                if distance <= -reach { return .closePanel }
                // A panel only under the pointer is not open yet: the swipe pins it, the way a
                // click on it would. One already pinned has nothing further to open.
                if distance >= reach, !pinned { return .openPanel }
                return .none
            }
            if distance >= reach { return .openPanel }
        }
        if case .compactTimer = context {
            let steps = timerSteps(travel: distance)
            return steps == 0 ? .none : .nudgeTimer(steps: steps)
        }
        guard verticalSwipe == .volume, dy != 0 else { return .none }
        return .volume(delta: level * volumeStep)
    }

    // MARK: - Gesture state (main thread only)

    private enum Axis { case undecided, horizontal, vertical }

    private var activePanel: String?
    private var axis: Axis = .undecided
    private var accumulatedX: CGFloat = 0
    /// Vertical distance seen but not applied yet, so throttling never loses movement.
    private var pendingY: CGFloat = 0
    /// The whole gesture's vertical distance, which a swipe and a timer's minutes are
    /// measured on. Never spent, unlike `pendingY`.
    private var accumulatedY: CGFloat = 0
    /// The timer whose pill the gesture is on, when it is on one; see `currentContext`.
    private var timerID: String?
    /// What this gesture has done to that timer so far.
    private var timerNudge = TimerNudge()
    private var firedSwipe = false
    private var consumedGesture = false
    private var lastEventAt = Date.distantPast
    private var lastVolumeAt = Date.distantPast
    private var lastTrackAt = Date.distantPast

    /// Resolves the default output device on every call, so it needs no `start()` and
    /// registers no CoreAudio listeners of its own.
    private lazy var audio = AudioMonitor()

    private init() {}

    // MARK: - Entry point

    /// Handles one scroll-wheel event. Returns true when the island took the event and the
    /// hosting view should swallow it.
    func handle(_ event: NSEvent, panel: String) -> Bool {
        guard event.type == .scrollWheel, Preferences.shared.gesturesEnabled else { return false }

        let now = Date()
        let phase = event.phase
        let momentum = event.momentumPhase
        if phase.contains(.began) || phase.contains(.mayBegin) || panel != activePanel
            || now.timeIntervalSince(lastEventAt) > Self.gestureGap {
            beginGesture(panel: panel)
        }
        lastEventAt = now

        // The fingers have lifted: keep swallowing what this gesture already owns, but never
        // start or continue anything on inertia alone.
        if !momentum.isEmpty { return consumedGesture }
        if phase.contains(.ended) || phase.contains(.cancelled) { return consumedGesture }

        let (dx, dy) = Self.deltas(from: event)
        accumulatedX += dx
        pendingY += dy
        accumulatedY += dy

        if axis == .undecided {
            let ax = abs(accumulatedX), ay = abs(pendingY)
            if max(ax, ay) >= Self.axisLockThreshold { axis = ax >= ay ? .horizontal : .vertical }
        }

        let context = currentContext(panel: panel)
        switch axis {
        case .undecided:
            // Too small to tell yet, and nothing is lost: both totals keep accumulating.
            return consumedGesture
        case .horizontal:
            pendingY = 0
            // A swipe that has stepped keeps the rest of its gesture, even where the section it
            // stepped to has a strip that would take it: those fingers were still finishing the
            // step, and the strip would otherwise scroll off under them.
            guard firedSwipe || Self.consumesHorizontalSwipes(context) else { return false }
            consumedGesture = true
            guard !firedSwipe else { return true }
            if perform(Self.decide(dx: accumulatedX, dy: 0, context: context), now: now, panel: panel) {
                firedSwipe = true
                accumulatedX = 0
            }
            return true
        case .vertical:
            // The same for a swipe that has opened or closed the panel: the rest of the gesture
            // is still that swipe, even over a list that would scroll, and `decide` lets none of
            // it act.
            guard firedSwipe || Self.consumesVerticalScroll(context) else { return false }
            consumedGesture = true
            guard now.timeIntervalSince(lastVolumeAt) >= Self.volumeInterval else { return true }
            // Option turns the scroll into the brightness, the way the rail has a slider for
            // each. A Mac whose display will not say what it is set to keeps the volume.
            let wantsBrightness = event.modifierFlags.contains(.option) && brightnessAvailable(now: now)
            // Control turns it into the keyboard's backlight, on a Mac that has one to set.
            // Control with Option is still the brightness, as it always was.
            let wantsKeyboard = event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.option)
                && KeyboardLight.shared.isAvailable
            let prefs = Preferences.shared
            let action = Self.decide(dx: 0, dy: pendingY, context: context, wantsBrightness: wantsBrightness,
                                     wantsKeyboard: wantsKeyboard,
                                     verticalSwipe: VerticalSwipe(preference: prefs.verticalSwipe),
                                     sensitivity: prefs.swipeSensitivity, travel: accumulatedY,
                                     swipeFired: firedSwipe)
            pendingY = 0
            lastVolumeAt = now
            switch action {
            case .openPanel, .closePanel:
                // Once per gesture: whatever the fingers do after the panel has opened or
                // closed is still that swipe (`swipeFired`), and nothing is ever started on its
                // inertia.
                if perform(action, now: now, panel: panel) { firedSwipe = true }
            default:
                perform(action, now: now, panel: panel)
            }
            return true
        }
    }

    private func beginGesture(panel: String) {
        activePanel = panel
        brightnessBase = nil
        keyboardBase = nil
        axis = .undecided
        accumulatedX = 0
        pendingY = 0
        accumulatedY = 0
        timerNudge = TimerNudge()
        firedSwipe = false
        consumedGesture = false
    }

    /// Trackpads report points; wheels report lines, and some mice only fill in `deltaX/Y`.
    private static func deltas(from event: NSEvent) -> (dx: CGFloat, dy: CGFloat) {
        // `decide` reads the deltas as the natural scroll direction gives them: the content
        // follows the fingers, so fingers up is a negative `dy`. With natural scrolling
        // switched off the deltas arrive the other way up, and two fingers up lowered the
        // volume and a swipe to the left skipped back. The event says which it is.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        if event.hasPreciseScrollingDeltas {
            return (event.scrollingDeltaX * sign, event.scrollingDeltaY * sign)
        }
        let x = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.deltaX
        let y = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        return (x * lineScale * sign, y * lineScale * sign)
    }

    // MARK: - Context

    /// Sections whose content scrolls by itself, and so keep their vertical scroll events.
    ///
    /// Controls is three lists — the networks, the devices, where the sound goes — and a
    /// scroll on any of them changed the volume instead, or closed the panel with "Open and
    /// close" chosen. Today is not here: it fits its rows to the room and drops what does not
    /// fit (`TodaySectionView.fit`), and its hours are one row across the width, so it has
    /// nothing to scroll and a scroll there is the volume, the way it is on Now Playing.
    static let scrollingSections: Set<HomeSection> = [.clipboard, .shelf, .notes, .windows, .notifications, .controls]

    /// Whether a section on screen has a strip running sideways with tiles out of sight: the
    /// Shelf's files and the Windows section's windows, counted as the find has narrowed them,
    /// since the narrowed strip is the one on screen. Read on every event, so the file that
    /// fills the strip past its width turns the swipe over to it at once, and a find that
    /// narrows it back hands the swipe back to the step.
    private static func scrollsSideways(_ section: HomeSection, query: String?) -> Bool {
        switch section {
        case .shelf:
            return stripOverflows(count: ShelfStripView.matching(ShelfStore.shared.items, query: query).count,
                                  across: ShelfStripView.tilesAcross)
        case .windows:
            return stripOverflows(count: WindowsSectionView.matching(WindowsMonitor.shared.windows, query: query).count,
                                  across: WindowsSectionView.tilesAcross)
        default:
            return false
        }
    }

    /// Also notes which timer's pill is showing, for a scroll that moves it.
    private func currentContext(panel: String) -> Context {
        let center = ActivityCenter.shared
        timerID = nil
        switch center.presentation(for: panel) {
        case .idle:
            return .idle
        case .compact(let activity, _):
            if case .nowPlaying = activity.content { return .compactNowPlaying }
            // A timer that has rung has nothing left to move; its pill is like any other.
            if case .timer(let state) = activity.content, !state.isFinished {
                timerID = activity.id
                return .compactTimer
            }
            return .otherCompact
        case .card:
            return .card
        case .panel(let view):
            let ring = center.ring
            let index = ring.firstIndex(of: view) ?? 0
            var scrolls = false
            var sideways = false
            if case .home(let tab) = view, let section = HomeSection(rawValue: tab) {
                scrolls = Self.scrollingSections.contains(section)
                sideways = Self.scrollsSideways(section, query: center.findQuery)
            }
            return .panel(index: index, count: ring.count, scrolls: scrolls, scrollsSideways: sideways,
                          pinned: center.openHere(panel))
        case .shelf:
            return .shelf
        }
    }

    // MARK: - Performing

    /// Returns true when the action actually happened (a cooldown can refuse it). `panel` is
    /// the island the gesture is on, which is the one a swipe opens.
    @discardableResult
    private func perform(_ action: Action, now: Date, panel: String) -> Bool {
        switch action {
        case .nextTrack:
            guard now.timeIntervalSince(lastTrackAt) >= Self.trackCooldown else { return false }
            lastTrackAt = now
            NowPlayingService.shared.next()
            Haptics.tap()
            return true
        case .previousTrack:
            guard now.timeIntervalSince(lastTrackAt) >= Self.trackCooldown else { return false }
            lastTrackAt = now
            NowPlayingService.shared.previous()
            Haptics.tap()
            return true
        case .stepView(let forward):
            guard now.timeIntervalSince(lastTrackAt) >= Self.trackCooldown else { return false }
            lastTrackAt = now
            // This island's view: on a second display, a swipe on the island that is only
            // peeking steps its own peek, not the panel pinned on the other one.
            if ActivityCenter.shared.step(forward: forward, wrap: false, panel: panel) { Haptics.soft() }
            return true
        case .volume(let delta):
            return applyVolume(delta: delta)
        case .brightness(let delta):
            return applyBrightness(delta: delta)
        case .keyboard(let delta):
            return applyKeyboardLight(delta: delta)
        case .openPanel:
            guard now.timeIntervalSince(lastTrackAt) >= Self.trackCooldown else { return false }
            guard ActivityCenter.shared.openBySwipe(panel: panel) else { return false }
            lastTrackAt = now
            // A swipe on a timer's pill passes a step's distance before it reaches this one,
            // and the timer moved as it went by. It was a swipe, not a nudge: those minutes go
            // back, and the card opens on the time that was there before it.
            _ = timerNudge.putBack(move: Self.moveTimer)
            // No click came with it, unlike an open from the pointer, so the hand gets the
            // same soft nod a view step gives.
            Haptics.soft()
            return true
        case .closePanel:
            guard now.timeIntervalSince(lastTrackAt) >= Self.trackCooldown else { return false }
            lastTrackAt = now
            let center = ActivityCenter.shared
            switch Self.closeTarget(openHere: center.openHere(panel), isOpen: center.isOpen) {
            case .everything:
                center.collapse(reason: "swipe")
            case .peekHere:
                // Only this island's peek closes, and it stays closed while the pointer rests
                // there; the panel pinned on the other display stays exactly as it was.
                IslandLog.island.notice("swipe closes the peek on \(panel, privacy: .public)")
                center.closePeek(panel: panel)
            }
            Haptics.soft()
            return true
        case .nudgeTimer(let steps):
            return nudgeTimer(toward: steps)
        case .none:
            return false
        }
    }

    /// Moves the timer under the pointer to where the gesture has asked for: `steps` minutes
    /// from where it was when the gesture began. Only what has not been applied yet is, with a
    /// tap for each change that lands; the pill's digits roll on their own.
    @discardableResult
    private func nudgeTimer(toward steps: Int) -> Bool {
        guard let id = timerID, timerNudge.nudge(id: id, toward: steps, move: Self.moveTimer) else { return false }
        Haptics.tap()
        return true
    }

    /// Moves a timer by `seconds` either way and answers how far it really went. Time comes
    /// off as well as going on — `IslandTimer.add(seconds:id:now:)` takes a negative figure,
    /// and never leaves less than a second — so a scroll down shortens the timer the way a
    /// scroll up lengthens it. A timer that has rung, or one that has gone, is not moved at
    /// all. The distance is `IslandTimer.adjustment`, the rule `add` itself applies, worked
    /// out at the same instant, so a put-back undoes exactly what landed.
    static func moveTimer(id: String, seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds != 0,
              let entry = IslandTimer.shared.entry(id: id), !entry.state.isFinished else { return 0 }
        let now = Date()
        let change = IslandTimer.adjustment(seconds, remaining: entry.state.remaining(at: now))
        guard change != 0 else { return 0 }
        IslandTimer.shared.add(seconds: seconds, id: id, now: now)
        return change
    }

    /// Where the backlight was when this gesture started, carried from event to event for the
    /// brightness's reason.
    private var keyboardBase: Double?

    @discardableResult
    private func applyKeyboardLight(delta: Double) -> Bool {
        guard delta != 0 else { return false }
        let light = KeyboardLight.shared
        guard light.isAvailable, let current = keyboardBase ?? light.read() else { return false }
        let target = KeyboardLight.clamped(current + delta)
        keyboardBase = target
        light.set(target)
        // Nothing else answers a scroll on the island, so this is the only display there is —
        // the same as the brightness's, and under its own switch.
        KeyboardLight.showHUD(level: target)
        return true
    }

    /// Whether this Mac's display answers a brightness read at all. Asked at most once a
    /// second: it is a DisplayServices round trip and a scroll is thirty events a second.
    private var brightnessCheckedAt = Date.distantPast
    private var brightnessIsAvailable = false

    private func brightnessAvailable(now: Date) -> Bool {
        if now.timeIntervalSince(brightnessCheckedAt) > 1 {
            brightnessCheckedAt = now
            brightnessIsAvailable = BrightnessControl.read() != nil
        }
        return brightnessIsAvailable
    }

    /// Where the brightness was when this gesture started, carried from event to event.
    private var brightnessBase: Double?

    @discardableResult
    private func applyBrightness(delta: Double) -> Bool {
        guard delta != 0 else { return false }
        // Read once at the start of a gesture and carried from there. A DisplayServices read
        // on every event of a thirty-a-second scroll is not worth its cost, and the value in
        // between is one this router has just written itself.
        guard let current = brightnessBase ?? BrightnessControl.read() else { return false }
        let target = min(1, max(0, current + delta))
        brightnessBase = target
        BrightnessControl.shared.set(target)
        postBrightnessHUD(level: target)
        return true
    }

    /// The same reasoning as the volume's: macOS draws nothing for a scroll on the island, and
    /// no slider moves where anybody can see it, so this display is the only answer there is.
    private func postBrightnessHUD(level: Double) {
        guard Preferences.shared.brightnessHUDEnabled else { return }
        let hud = LevelHUD(kind: .brightness, level: level)
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85),
                                        duration: 1.5, haptic: false)
    }

    /// One key press of volume, through the same path a scroll takes — the same write, the
    /// same unmute on the way up, the same display. macOS moves the volume in sixteenths for
    /// the volume keys, and so does this.
    static let keyStep: Double = 1.0 / 16.0

    func nudgeVolume(up: Bool) {
        applyVolume(delta: up ? Self.keyStep : -Self.keyStep)
    }

    @discardableResult
    private func applyVolume(delta: Double) -> Bool {
        guard delta != 0, let current = audio.currentVolume() else { return false }
        let target = Float(min(1, max(0, Double(current) + delta)))
        // The island's own write, like the rail's slider and the media keys — so the CoreAudio
        // listener does not put a second display up for a change this one is about to announce
        // itself. See `LocalWrite`.
        AudioOutputs.markLocalWrite()
        let applied = target == current ? true : audio.setVolume(target)
        // Scrolling up unmutes, the way the volume keys do.
        var muted = audio.isMuted() ?? false
        if muted, delta > 0, audio.setMuted(false) { muted = false }
        postVolumeHUD(level: applied ? target : current, muted: muted)
        return applied
    }

    /// `AudioMonitor`'s CoreAudio listener normally reports our own write and shows the HUD,
    /// but it only runs while the app is monitoring audio, and we would rather not depend on
    /// that. Posting here is safe: the alert carries the same id, so a duplicate replaces
    /// itself.
    private func postVolumeHUD(level: Float, muted: Bool) {
        // Not gated on the island having taken the keys over, unlike every other path: a
        // scroll on the island is the island's own control, macOS draws nothing for it, and
        // no slider moves where you can see it. This display is the only answer there is.
        guard Preferences.shared.volumeHUDEnabled else { return }
        let hud = LevelHUD.volume(level: Double(level), isMuted: muted, output: AudioOutputs.currentOutput())
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85),
                                        duration: 1.5, haptic: false)
    }
}
