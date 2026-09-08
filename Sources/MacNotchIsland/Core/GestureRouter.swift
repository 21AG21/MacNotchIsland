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
///   scrolls by itself.
/// - Anything else is handed straight back to SwiftUI, so the clipboard list and the shelf
///   strip keep scrolling normally.
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
        case otherCompact
        /// A system card (an alert with a large view).
        case card
        /// The panel: `index` is the current view's position in the ring of `count` views;
        /// `scrolls` when the section scrolls by itself (a list, a strip).
        case panel(index: Int, count: Int, scrolls: Bool)
        case shelf
    }

    enum Action: Equatable {
        case nextTrack
        case previousTrack
        case stepView(forward: Bool)
        /// Change in output volume, on the 0...1 scale.
        case volume(delta: Double)
        case none
    }

    /// Accumulated horizontal distance, in points, that makes a track skip.
    static let swipeThreshold: CGFloat = 40
    /// A step between views asks for a little more: a scroll with a tilt must not change views.
    static let viewSwipeThreshold: CGFloat = 55
    /// Volume change per point of vertical scrolling.
    static let volumeStep: Double = 0.004
    /// How far a gesture has to travel before it is locked to one axis.
    static let axisLockThreshold: CGFloat = 6
    /// A classic wheel reports lines, not points; this makes one line comparable with a
    /// trackpad's points.
    static let lineScale: CGFloat = 16
    /// A pause this long starts a new gesture (mouse wheels carry no phase information).
    static let gestureGap: TimeInterval = 0.25
    /// At most ~30 volume writes a second.
    static let volumeInterval: TimeInterval = 1.0 / 30.0
    /// Two track skips (or view steps) can never be closer together than this.
    static let trackCooldown: TimeInterval = 0.6

    /// UserDefaults key for the Home section the panel last showed.
    static let homeTabKey = "homeTab"

    /// Whether a horizontal swipe means anything here.
    static func consumesHorizontalSwipes(_ context: Context) -> Bool {
        switch context {
        case .compactNowPlaying: return true
        case .panel(_, let count, _): return count > 1
        case .idle, .otherCompact, .card, .shelf: return false
        }
    }

    /// Whether a vertical scroll should change the volume. A section that scrolls keeps its
    /// own scroll events.
    static func consumesVerticalScroll(_ context: Context) -> Bool {
        switch context {
        case .idle, .compactNowPlaying, .otherCompact, .card: return true
        case .panel(_, _, let scrolls): return !scrolls
        case .shelf: return false
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
    static func decide(dx: CGFloat, dy: CGFloat, context: Context) -> Action {
        let threshold: CGFloat
        if case .panel = context { threshold = viewSwipeThreshold } else { threshold = swipeThreshold }
        if abs(dx) > threshold, abs(dx) >= abs(dy), consumesHorizontalSwipes(context) {
            let forward = dx < 0
            switch context {
            case .compactNowPlaying:
                return forward ? .nextTrack : .previousTrack
            case .panel(let index, let count, _):
                let next = index + (forward ? 1 : -1)
                guard next >= 0, next < count else { return .none }
                return .stepView(forward: forward)
            default:
                return .none
            }
        }
        if dy != 0, consumesVerticalScroll(context) {
            return .volume(delta: Double(-dy) * volumeStep)
        }
        return .none
    }

    // MARK: - Gesture state (main thread only)

    private enum Axis { case undecided, horizontal, vertical }

    private var activePanel: String?
    private var axis: Axis = .undecided
    private var accumulatedX: CGFloat = 0
    /// Vertical distance seen but not applied yet, so throttling never loses movement.
    private var pendingY: CGFloat = 0
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
            guard Self.consumesHorizontalSwipes(context) else { return false }
            consumedGesture = true
            guard !firedSwipe else { return true }
            if perform(Self.decide(dx: accumulatedX, dy: 0, context: context), now: now) {
                firedSwipe = true
                accumulatedX = 0
            }
            return true
        case .vertical:
            guard Self.consumesVerticalScroll(context) else { return false }
            consumedGesture = true
            guard now.timeIntervalSince(lastVolumeAt) >= Self.volumeInterval else { return true }
            let action = Self.decide(dx: 0, dy: pendingY, context: context)
            pendingY = 0
            lastVolumeAt = now
            perform(action, now: now)
            return true
        }
    }

    private func beginGesture(panel: String) {
        activePanel = panel
        axis = .undecided
        accumulatedX = 0
        pendingY = 0
        firedSwipe = false
        consumedGesture = false
    }

    /// Trackpads report points; wheels report lines, and some mice only fill in `deltaX/Y`.
    private static func deltas(from event: NSEvent) -> (dx: CGFloat, dy: CGFloat) {
        if event.hasPreciseScrollingDeltas {
            return (event.scrollingDeltaX, event.scrollingDeltaY)
        }
        let x = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.deltaX
        let y = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        return (x * lineScale, y * lineScale)
    }

    // MARK: - Context

    /// Sections whose content scrolls by itself, and so keep their vertical scroll events.
    static let scrollingSections: Set<HomeSection> = [.clipboard, .shelf, .notes, .today, .windows]

    private func currentContext(panel: String) -> Context {
        let center = ActivityCenter.shared
        switch center.presentation(for: panel) {
        case .idle:
            return .idle
        case .compact(let activity, _):
            if case .nowPlaying = activity.content { return .compactNowPlaying }
            return .otherCompact
        case .card:
            return .card
        case .panel(let view):
            let ring = center.ring
            let index = ring.firstIndex(of: view) ?? 0
            var scrolls = false
            if case .home(let tab) = view, let section = HomeSection(rawValue: tab) {
                scrolls = Self.scrollingSections.contains(section)
            }
            return .panel(index: index, count: ring.count, scrolls: scrolls)
        case .shelf:
            return .shelf
        }
    }

    // MARK: - Performing

    /// Returns true when the action actually happened (a cooldown can refuse it).
    @discardableResult
    private func perform(_ action: Action, now: Date) -> Bool {
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
            if ActivityCenter.shared.step(forward: forward, wrap: false) { Haptics.soft() }
            return true
        case .volume(let delta):
            return applyVolume(delta: delta)
        case .none:
            return false
        }
    }

    @discardableResult
    private func applyVolume(delta: Double) -> Bool {
        guard delta != 0, let current = audio.currentVolume() else { return false }
        let target = Float(min(1, max(0, Double(current) + delta)))
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
        guard Preferences.shared.volumeHUDEnabled else { return }
        let hud = LevelHUD(kind: .volume, level: Double(level), isMuted: muted)
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85),
                                        duration: 1.5, haptic: false)
    }
}
