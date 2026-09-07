import AppKit
import Foundation

/// Trackpad gestures on the island.
///
/// Every gesture reaches us as a scroll-wheel event on `NotchHostingView`, which only sees
/// events inside the island's footprint (its `hitTest` returns nil everywhere else), so
/// nothing outside the island is affected.
///
/// - A horizontal swipe skips tracks while Now Playing owns the island, and cycles the Home
///   panel's tabs while Home is open.
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
        case expandedNowPlaying
        case otherCompact
        case otherExpanded
        /// The Home panel. `tab` is the stored tab, `available` the tabs the user's
        /// preferences currently allow, in tab-bar order.
        case home(tab: String, available: [String])
        case shelf
    }

    enum Action: Equatable {
        case nextTrack
        case previousTrack
        case selectTab(String)
        /// Change in output volume, on the 0...1 scale.
        case volume(delta: Double)
        case none
    }

    /// Accumulated horizontal distance, in points, that makes a swipe.
    static let swipeThreshold: CGFloat = 40
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
    /// Two track skips can never be closer together than this.
    static let trackCooldown: TimeInterval = 0.6

    /// UserDefaults key shared with `HomeExpandedView`.
    static let homeTabKey = "homeTab"
    /// Raw values of `HomeExpandedView`'s `HomeTab`, in tab-bar order.
    /// Must match HomeExpandedView.HomeTab order; the tab bar hides tabs whose feature is off.
    static let homeTabOrder = ["music", "shelf", "clipboard", "actions", "mirror", "stats", "weather"]
    /// The tab Home falls back to; it can never be switched off.
    static let defaultHomeTab = "music"

    /// The tab Home actually shows: the stored one, unless its feature has been switched off.
    /// Mirrors `HomeExpandedView.selection`.
    static func effectiveTab(_ tab: String, available: [String]) -> String {
        available.contains(tab) ? tab : defaultHomeTab
    }

    /// Whether a horizontal swipe means anything here. The shelf strip scrolls sideways
    /// itself, so it keeps its own scroll events.
    static func consumesHorizontalSwipes(_ context: Context) -> Bool {
        switch context {
        case .compactNowPlaying, .expandedNowPlaying:
            return true
        case .home(let tab, let available):
            return effectiveTab(tab, available: available) != "shelf" && available.count > 1
        case .idle, .otherCompact, .otherExpanded, .shelf:
            return false
        }
    }

    /// Whether a vertical scroll should change the volume. Home and the shelf are left alone
    /// because their content scrolls.
    static func consumesVerticalScroll(_ context: Context) -> Bool {
        switch context {
        case .idle, .compactNowPlaying, .expandedNowPlaying, .otherCompact:
            return true
        case .otherExpanded, .home, .shelf:
            return false
        }
    }

    /// The whole gesture policy, as a pure function.
    ///
    /// `dx` is the horizontal distance accumulated so far in the current gesture and `dy` the
    /// vertical distance still to be applied, both as AppKit reports them: with the default
    /// (natural) scroll direction moving the fingers left gives a negative `dx` and moving
    /// them up a negative `dy`. So a swipe to the left advances (next track, next tab) and a
    /// swipe up raises the volume.
    static func decide(dx: CGFloat, dy: CGFloat, context: Context) -> Action {
        if abs(dx) > swipeThreshold, abs(dx) >= abs(dy), consumesHorizontalSwipes(context) {
            let forward = dx < 0
            switch context {
            case .compactNowPlaying, .expandedNowPlaying:
                return forward ? .nextTrack : .previousTrack
            case .home(let tab, let available):
                let tabs = available.isEmpty ? [defaultHomeTab] : available
                let current = effectiveTab(tab, available: tabs)
                guard tabs.count > 1, let i = tabs.firstIndex(of: current) else { return .none }
                let next = forward ? (i + 1) % tabs.count : (i - 1 + tabs.count) % tabs.count
                return .selectTab(tabs[next])
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

    private func currentContext(panel: String) -> Context {
        switch ActivityCenter.shared.presentation(for: panel) {
        case .idle:
            return .idle
        case .compact(let activity, _):
            if case .nowPlaying = activity.content { return .compactNowPlaying }
            return .otherCompact
        case .expanded(let activity):
            if case .nowPlaying = activity.content { return .expandedNowPlaying }
            return .otherExpanded
        case .home:
            let stored = UserDefaults.standard.string(forKey: Self.homeTabKey) ?? Self.defaultHomeTab
            return .home(tab: stored, available: availableHomeTabs)
        case .shelf:
            return .shelf
        }
    }

    /// Mirrors `HomeExpandedView.availableTabs`.
    private var availableHomeTabs: [String] {
        let prefs = Preferences.shared
        return Self.homeTabOrder.filter { tab in
            switch tab {
            case "shelf": return prefs.shelfEnabled
            case "clipboard": return prefs.clipboardEnabled
            case "actions": return prefs.quickActionsEnabled
            case "mirror": return prefs.mirrorEnabled
            case "stats": return prefs.statsEnabled
            case "weather": return prefs.weatherEnabled
            default: return true
            }
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
        case .selectTab(let tab):
            UserDefaults.standard.set(tab, forKey: Self.homeTabKey)
            Haptics.soft()
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
