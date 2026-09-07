import SwiftUI
import Combine

/// The brain of the island. Owns live activities and transient alerts, tracks hover /
/// drag / click state, and derives what the island should currently present.
///
/// Rules mirror the iPhone's Dynamic Island:
/// - Alerts (charging, AirPods, Focus, unlock, volume) briefly take over the island.
/// - The highest-priority live activity owns the island; the next one becomes the detached
///   "minimal" bubble on the right. Tapping the bubble swaps them.
/// - Hovering (the Mac's long-press) expands; leaving collapses after a short grace period.
/// - With nothing live, hovering opens the Home panel (music, timer presets, file shelf).
final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()

    @Published private(set) var activities: [IslandActivity] = []
    @Published private(set) var alert: IslandActivity? = nil
    /// Which panel (screen) the pointer is hovering / dragging over. Interaction state is
    /// per screen so an island on one display doesn't open the one on another.
    @Published private(set) var hoverPanel: String? = nil
    @Published private(set) var dragPanel: String? = nil
    var isHovering: Bool { hoverPanel != nil }
    var isDragTargeted: Bool { dragPanel != nil }
    @Published private(set) var manuallyExpanded = false
    @Published private(set) var homeForced = false
    @Published private(set) var forcedExpandedID: String? = nil
    @Published private(set) var pinnedID: String? = nil
    @Published var micInUse = false
    @Published var cameraInUse = false

    private var alertWork: DispatchWorkItem?
    private var pendingAlerts: [(activity: IslandActivity, queuedAt: Date, duration: TimeInterval?)] = []
    private var hoverWork: DispatchWorkItem?
    private var homeWork: DispatchWorkItem?
    private var forcedWork: DispatchWorkItem?
    private var expiryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.pruneExpired()
        }
        Preferences.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Clears every piece of state. Used by the test suite.
    func resetForTesting() {
        alertWork?.cancel(); hoverWork?.cancel(); homeWork?.cancel(); forcedWork?.cancel()
        activities = []
        alert = nil
        pendingAlerts.removeAll()
        hoverPanel = nil
        dragPanel = nil
        manuallyExpanded = false
        homeForced = false
        forcedExpandedID = nil
        pinnedID = nil
        micInUse = false
        cameraInUse = false
    }

    // MARK: - Derived state

    var privacyIndicatorsVisible: Bool {
        Preferences.shared.privacyIndicatorsEnabled && (micInUse || cameraInUse)
    }

    var sortedActivities: [IslandActivity] {
        activities.sorted { a, b in
            if let pinned = pinnedID {
                if a.id == pinned { return true }
                if b.id == pinned { return false }
            }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.startedAt > b.startedAt
        }
    }

    var primary: IslandActivity? { sortedActivities.first }
    var secondary: IslandActivity? { sortedActivities.dropFirst().first }

    /// Presentation independent of which screen is asking (tests, hit-testing fallbacks).
    var presentation: IslandPresentation { presentation(for: nil) }

    /// Presentation for one panel. Hover and drag only affect the panel they happen on;
    /// alerts, live activities and programmatic expansion show everywhere.
    func presentation(for panel: String?) -> IslandPresentation {
        let prefs = Preferences.shared
        let hovering = hoverPanel != nil && (panel == nil || hoverPanel == panel)
        let dragging = dragPanel != nil && (panel == nil || dragPanel == panel)

        if dragging && prefs.shelfEnabled { return .shelf }

        if let alert {
            let wantsExpanded = alert.presentation == .expanded || hovering || manuallyExpanded
            if wantsExpanded && alert.content.hasExpandedView { return .expanded(alert) }
            return .compact(alert, bubble: nil)
        }

        if homeForced { return .home }

        let live = sortedActivities
        if let primary = live.first {
            let hoverExpand = hovering && prefs.hoverToExpand
            let forced = forcedExpandedID == primary.id
            if (hoverExpand || manuallyExpanded || forced) && primary.content.hasExpandedView {
                return .expanded(primary)
            }
            return .compact(primary, bubble: live.dropFirst().first)
        }

        if hovering && prefs.expandOnIdleHover { return .home }
        return .idle
    }

    func activity(id: String) -> IslandActivity? { activities.first { $0.id == id } }

    // MARK: - Live activities

    func upsert(_ activity: IslandActivity) {
        if let i = activities.firstIndex(where: { $0.id == activity.id }) {
            var a = activity
            a.startedAt = activities[i].startedAt
            if activities[i] != a { activities[i] = a }
        } else {
            activities.append(activity)
            Haptics.soft()
        }
    }

    func update(id: String, _ mutate: (inout IslandActivity) -> Void) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        var a = activities[i]
        mutate(&a)
        activities[i] = a
    }

    func end(id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        activities.removeAll { $0.id == id }
        if pinnedID == id { pinnedID = nil }
        if forcedExpandedID == id { forcedExpandedID = nil }
    }

    func end(kind: ActivityKind) {
        for a in activities where a.kind == kind { end(id: a.id) }
    }

    /// Make the bubble activity the primary one (tap on the minimal bubble).
    func promote(id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        pinnedID = id
        Haptics.tap()
    }

    /// Temporarily force an activity into its expanded view (e.g. a timer finishing).
    func forceExpanded(id: String, for seconds: TimeInterval = 6) {
        forcedWork?.cancel()
        forcedExpandedID = id
        // A forced activity must be the primary one, or nothing visible happens.
        if activities.contains(where: { $0.id == id }) { pinnedID = id }
        Haptics.tap()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.forcedExpandedID == id else { return }
            self.forcedExpandedID = nil
        }
        forcedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func pruneExpired() {
        let now = Date()
        let expired = activities.filter { ($0.expiresAt ?? .distantFuture) < now }
        for a in expired { end(id: a.id) }
    }

    // MARK: - Alerts

    /// How important an alert is; a lower-ranked alert never cuts off a higher-ranked one.
    static func alertRank(_ activity: IslandActivity) -> Int {
        switch activity.content {
        case .hud: return 1
        case .silent: return 2
        case .custom: return activity.id == "capslock" ? 1 : 3
        case .focus, .unlock: return 3
        case .download, .bluetooth: return 4
        case .battery(let b): return (b.event == .low || b.event == .critical) ? 6 : 5
        default: return 3
        }
    }

    func showAlert(_ activity: IslandActivity, duration: TimeInterval? = nil, haptic: Bool = true) {
        if let current = alert, current.id != activity.id, Self.alertRank(current) > Self.alertRank(activity) {
            // Queue behind the more important alert (a volume tick must not hide a low-battery warning).
            pendingAlerts.removeAll { $0.activity.id == activity.id }
            if pendingAlerts.count < 3 { pendingAlerts.append((activity, Date(), duration)) }
            return
        }
        alertWork?.cancel()
        alert = activity
        if haptic { Haptics.tap() }
        scheduleAlertDismiss(id: activity.id, after: duration ?? Preferences.shared.alertDuration)
    }

    private func scheduleAlertDismiss(id: String, after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.alert?.id == id else { return }
            // Keep a real alert up while the pointer is on it, like holding a finger on the island;
            // very short confirmations ("Copied") expire regardless, since a click leaves the pointer there.
            if (self.isHovering || self.isDragTargeted) && seconds > 1.5 {
                self.scheduleAlertDismiss(id: id, after: 1.0)
            } else {
                self.alert = nil
                self.showNextPendingAlert()
            }
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func showNextPendingAlert() {
        let now = Date()
        // Transient HUD-style alerts go stale quickly; anything else is still worth showing.
        pendingAlerts.removeAll { now.timeIntervalSince($0.queuedAt) > (Self.alertRank($0.activity) <= 2 ? 2 : 15) }
        guard !pendingAlerts.isEmpty else { return }
        pendingAlerts.sort { Self.alertRank($0.activity) > Self.alertRank($1.activity) }
        let next = pendingAlerts.removeFirst()
        showAlert(next.activity, duration: next.duration, haptic: false)
    }

    func dismissAlert() {
        alertWork?.cancel()
        alert = nil
        pendingAlerts.removeAll()
    }

    // MARK: - Interaction

    func setHovering(_ hovering: Bool, panel: String = "main") {
        hoverWork?.cancel()
        let delay = hovering ? Preferences.shared.hoverDelay : 0.35
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if hovering {
                guard self.hoverPanel != panel else { return }
            } else {
                guard self.hoverPanel == panel else { return }
            }
            let before = self.presentation(for: panel)
            self.hoverPanel = hovering ? panel : nil
            if !hovering { self.manuallyExpanded = false }
            if before.isExpanded != self.presentation(for: panel).isExpanded { Haptics.tap() }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setDragTargeted(_ targeted: Bool, panel: String = "main") {
        if targeted {
            guard dragPanel != panel else { return }
            dragPanel = panel
            Haptics.tap()
        } else {
            guard dragPanel == panel || panel == "main" else { return }
            dragPanel = nil
        }
    }

    func tap() {
        switch presentation {
        case .compact(let a, _):
            if let open = a.openAction {
                open.perform()
            } else if a.content.hasExpandedView {
                manuallyExpanded = true
            }
            Haptics.tap()
        case .idle:
            if Preferences.shared.expandOnIdleHover { showHome() }
        default:
            break
        }
    }

    func toggleManualExpansion() {
        manuallyExpanded.toggle()
        Haptics.tap()
    }

    func collapse() {
        manuallyExpanded = false
        homeForced = false
        forcedExpandedID = nil
        if !isHovering { alert = nil }
    }

    /// Keep the current panel open while a menu or share sheet is in flight (the pointer
    /// leaves the island when a menu opens, which would otherwise collapse it).
    func holdOpen(for seconds: TimeInterval = 10) {
        homeWork?.cancel()
        homeForced = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isHovering { self.holdOpen(for: 1) } else { self.homeForced = false }
        }
        homeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Open the Home panel programmatically (menu bar, URL scheme).
    func showHome(for seconds: TimeInterval = 5) {
        homeWork?.cancel()
        homeForced = true
        Haptics.tap()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isHovering { self.showHome(for: 1) } else { self.homeForced = false }
        }
        homeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
