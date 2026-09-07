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
    @Published private(set) var isHovering = false
    @Published private(set) var isDragTargeted = false
    @Published private(set) var manuallyExpanded = false
    @Published private(set) var homeForced = false
    @Published private(set) var forcedExpandedID: String? = nil
    @Published private(set) var pinnedID: String? = nil
    @Published var micInUse = false
    @Published var cameraInUse = false

    private var alertWork: DispatchWorkItem?
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

    var presentation: IslandPresentation {
        let prefs = Preferences.shared

        if isDragTargeted && prefs.shelfEnabled { return .shelf }

        if let alert {
            let wantsExpanded = alert.presentation == .expanded || isHovering || manuallyExpanded
            if wantsExpanded && alert.content.hasExpandedView { return .expanded(alert) }
            return .compact(alert, bubble: nil)
        }

        if homeForced { return .home }

        let live = sortedActivities
        if let primary = live.first {
            let hoverExpand = isHovering && prefs.hoverToExpand
            let forced = forcedExpandedID == primary.id
            if (hoverExpand || manuallyExpanded || forced) && primary.content.hasExpandedView {
                return .expanded(primary)
            }
            return .compact(primary, bubble: live.dropFirst().first)
        }

        if isHovering && prefs.expandOnIdleHover { return .home }
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

    func showAlert(_ activity: IslandActivity, duration: TimeInterval? = nil, haptic: Bool = true) {
        alertWork?.cancel()
        alert = activity
        if haptic { Haptics.tap() }
        scheduleAlertDismiss(id: activity.id, after: duration ?? Preferences.shared.alertDuration)
    }

    private func scheduleAlertDismiss(id: String, after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.alert?.id == id else { return }
            // Keep the alert up while the pointer is on it, like holding a finger on the island.
            if self.isHovering || self.isDragTargeted {
                self.scheduleAlertDismiss(id: id, after: 1.0)
            } else {
                self.alert = nil
            }
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismissAlert() {
        alertWork?.cancel()
        alert = nil
    }

    // MARK: - Interaction

    func setHovering(_ hovering: Bool) {
        hoverWork?.cancel()
        let delay = hovering ? Preferences.shared.hoverDelay : 0.35
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isHovering != hovering else { return }
            let before = self.presentation
            self.isHovering = hovering
            if !hovering { self.manuallyExpanded = false }
            if before.isExpanded != self.presentation.isExpanded { Haptics.tap() }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setDragTargeted(_ targeted: Bool) {
        guard isDragTargeted != targeted else { return }
        isDragTargeted = targeted
        if targeted { Haptics.tap() }
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
