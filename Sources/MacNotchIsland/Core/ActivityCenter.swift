import SwiftUI
import Combine

/// The brain of the island. Owns live activities and transient alerts, tracks hover /
/// drag / click state, and derives what the island should currently present.
///
/// Rules mirror the iPhone's Dynamic Island, translated to a pointer and a keyboard:
/// - Alerts (charging, AirPods, Focus, unlock, volume) briefly take over the island.
/// - The most recently started live activity owns the island; the other becomes the detached
///   "minimal" bubble on the right. Clicking the bubble swaps them. A call, or a timer that
///   just rang, always wins regardless of age.
/// - Nothing happens on hover. A click on the island opens it (the activity's expanded view,
///   or the Home panel when nothing is live); a click on the island again, a click anywhere
///   else, Escape or the global shortcut closes it. Shortcut modifiers + Tab cycles through
///   every open-able view; with Shift it cycles back.
/// - Files dragged onto the island open the shelf for the duration of the drag.
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
    /// What the user opened by clicking or with the keyboard. Stays open until dismissed;
    /// nothing about the pointer's position changes it.
    @Published private(set) var openView: IslandView? = nil {
        didSet { if (openView == nil) != (oldValue == nil) { openStateChanged() } }
    }
    /// The panel whose island is being held down, for the press-in feedback.
    @Published private(set) var pressedPanel: String? = nil
    @Published private(set) var forcedExpandedID: String? = nil
    @Published private(set) var pinnedID: String? = nil
    @Published var micInUse = false
    @Published var cameraInUse = false
    /// True while a full-screen app is frontmost and the user asked to hide there.
    @Published var fullscreenSuppressed = false
    /// True while an app the user listed under "hide for these apps" is frontmost.
    @Published var appSuppressed = false

    /// Nothing is drawn while suppressed (user pause or full-screen app).
    var isSuppressed: Bool {
        if fullscreenSuppressed || appSuppressed { return true }
        let until = Preferences.shared.pausedUntil
        return until > 0 && Date().timeIntervalSince1970 < until
    }

    private var alertWork: DispatchWorkItem?
    private var pendingAlerts: [(activity: IslandActivity, queuedAt: Date, duration: TimeInterval?)] = []
    private var hoverWork: DispatchWorkItem?
    private var homeWork: DispatchWorkItem?
    private var forcedWork: DispatchWorkItem?
    /// Watches for clicks outside the island while it is open, the way a transient popover does.
    private var outsideClickMonitor: Any?
    private var expiryTimer: Timer?
    private var lastSuppressed = false
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
        pressedPanel = nil
        openView = nil
        forcedExpandedID = nil
        pinnedID = nil
        micInUse = false
        cameraInUse = false
    }

    // MARK: - Derived state

    var privacyIndicatorsVisible: Bool {
        Preferences.shared.privacyIndicatorsEnabled && (micInUse || cameraInUse)
    }

    /// Island order. The iPhone gives the main pill to whatever started most recently and
    /// demotes the older activity to the bubble, so starting a timer while music plays shows the
    /// timer, and pressing play while a timer runs brings the music back. Two exceptions: an
    /// activity the user pinned by clicking its bubble, and anything urgent (a call, a timer
    /// that has just rung). Activities of one kind are grouped, ordered by their own priority
    /// (the soonest of several timers), so a second timer never shuffles the music.
    var sortedActivities: [IslandActivity] {
        Self.ordered(activities, pinnedID: pinnedID)
    }

    /// Priority at or above this always takes the island, whatever started later.
    static let urgentPriority = 100

    static func ordered(_ activities: [IslandActivity], pinnedID: String?) -> [IslandActivity] {
        var newestByKind: [ActivityKind: Date] = [:]
        for a in activities {
            newestByKind[a.kind] = max(newestByKind[a.kind] ?? .distantPast, a.startedAt)
        }
        return activities.sorted { a, b in
            if let pinned = pinnedID {
                if a.id == pinned { return true }
                if b.id == pinned { return false }
            }
            let urgentA = a.priority >= urgentPriority, urgentB = b.priority >= urgentPriority
            if urgentA != urgentB { return urgentA }
            if a.kind != b.kind {
                let ra = newestByKind[a.kind] ?? a.startedAt, rb = newestByKind[b.kind] ?? b.startedAt
                if ra != rb { return ra > rb }
            }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.startedAt > b.startedAt
        }
    }

    var primary: IslandActivity? { sortedActivities.first }
    var secondary: IslandActivity? { sortedActivities.dropFirst().first }

    /// Presentation independent of which screen is asking (tests, hit-testing fallbacks).
    var presentation: IslandPresentation { presentation(for: nil) }

    /// Forget hover / drag / manual expansion, e.g. when the island is hidden under the pointer
    /// so it doesn't reappear expanded later with no pointer near it.
    func clearInteraction() {
        hoverWork?.cancel()
        hoverPanel = nil
        dragPanel = nil
        pressedPanel = nil
        openView = nil
    }

    /// True while something the user opened is on screen.
    var isOpen: Bool { openView != nil }

    /// Hide the island for a while (presentations, screen sharing). 0 clears the pause.
    func pause(for seconds: TimeInterval) {
        if seconds > 0 { clearInteraction() }
        Preferences.shared.pausedUntil = seconds > 0 ? Date().timeIntervalSince1970 + seconds : 0
        objectWillChange.send()
        if seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.5) { [weak self] in self?.objectWillChange.send() }
        }
    }

    /// Presentation for one panel. Hover and drag only affect the panel they happen on;
    /// alerts, live activities and programmatic expansion show everywhere.
    func presentation(for panel: String?) -> IslandPresentation {
        let prefs = Preferences.shared
        let hovering = hoverPanel != nil && (panel == nil || hoverPanel == panel)
        let dragging = dragPanel != nil && (panel == nil || dragPanel == panel)

        if dragging && prefs.shelfEnabled { return .shelf }

        if let alert {
            let wantsExpanded = alert.presentation == .expanded || (hovering && prefs.hoverToExpand)
                || openView == .activity(id: alert.id)
            if wantsExpanded && alert.content.hasExpandedView { return .expanded(alert) }
            return .compact(alert, bubble: nil)
        }

        let live = sortedActivities
        switch openView {
        case .home:
            return .home
        case .activity(let id):
            if let a = live.first(where: { $0.id == id }), a.content.hasExpandedView { return .expanded(a) }
        case nil:
            break
        }

        if let primary = live.first {
            let hoverExpand = hovering && prefs.hoverToExpand
            let forced = forcedExpandedID == primary.id
            if (hoverExpand || forced) && primary.content.hasExpandedView {
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
        if openView == .activity(id: id) { openView = nil }
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
        // A pause persisted across a relaunch has no timer of its own; notice when it ends.
        let suppressed = isSuppressed
        if suppressed != lastSuppressed {
            lastSuppressed = suppressed
            objectWillChange.send()
        }
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
                if self.openView == .activity(id: id) { self.openView = nil }
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
        if let alert, openView == .activity(id: alert.id) { openView = nil }
        alert = nil
        pendingAlerts.removeAll()
    }

    // MARK: - Interaction

    /// Tracks which panel the pointer is over. Nothing opens because of it unless the user
    /// switched the hover options on; alerts merely stay up a little longer under the pointer.
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
            self.hoverPanel = hovering ? panel : nil
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Press-in feedback: the island shrinks slightly under the pointer, like the iPhone's
    /// island under a finger.
    func setPressed(_ pressed: Bool, panel: String = "main") {
        let next: String? = pressed ? panel : nil
        if pressedPanel != next { pressedPanel = next }
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

    /// A click on the island. Compact: open what is showing. Expanded: close it again, the way a
    /// menu bar extra toggles. Idle: open the Home panel. Alerts without a large view perform
    /// their action instead.
    func tap(panel: String = "main") {
        switch presentation(for: panel) {
        case .compact(let a, _):
            if a.content.hasExpandedView {
                open(.activity(id: a.id))
            } else if let action = a.openAction {
                action.perform()
                Haptics.tap()
            }
        case .expanded:
            collapse()
        case .idle:
            open(.home(tab: Self.currentHomeTab))
        case .home, .shelf:
            break
        }
    }

    /// Opens a view and keeps it open until `collapse()`.
    func open(_ view: IslandView) {
        homeWork?.cancel()
        lastInteraction = Date()
        if case .home(let tab) = view { Self.selectHomeTab(tab) }
        if openView != view {
            openView = view
            Haptics.tap()
        }
    }

    /// The global shortcut: close whatever is open, else open the main activity, else Home.
    func toggle() {
        if isOpen || presentation.isExpanded {
            collapse()
        } else if let primary = primary, primary.content.hasExpandedView {
            open(.activity(id: primary.id))
        } else {
            open(.home(tab: Self.currentHomeTab))
        }
    }

    /// Every view the keyboard can reach, in island order: each live activity's expanded view,
    /// then the Home panel's tabs.
    var keyboardRing: [IslandView] {
        let activities = sortedActivities.filter { $0.content.hasExpandedView }.map { IslandView.activity(id: $0.id) }
        let tabs = GestureRouter.availableHomeTabs(Preferences.shared).map { IslandView.home(tab: $0) }
        return activities + tabs
    }

    /// Shortcut modifiers + Tab (forward) or Shift + Tab (backward). Closed: opens the first
    /// (or last) view. Open: moves one step, wrapping around.
    func cycleView(forward: Bool) {
        let ring = keyboardRing
        guard !ring.isEmpty else { return }
        let next: IslandView
        if let current = openView, let i = ring.firstIndex(of: current) {
            next = ring[(i + (forward ? 1 : ring.count - 1)) % ring.count]
        } else {
            next = forward ? ring[0] : ring[ring.count - 1]
        }
        open(next)
        Haptics.soft()
    }

    func collapse() {
        homeWork?.cancel()
        openView = nil
        forcedExpandedID = nil
        if !isHovering { alert = nil }
    }

    /// Menus and share sheets used to need this to survive the pointer leaving; an open island
    /// no longer closes on its own, so this only cancels a pending timed close.
    func holdOpen(for seconds: TimeInterval = 10) {
        homeWork?.cancel()
    }

    /// Open the Home panel programmatically (menu bar, URL scheme, the welcome tour). With a
    /// duration it closes itself again unless the user has interacted with it since.
    func showHome(for seconds: TimeInterval = 0) {
        open(.home(tab: Self.currentHomeTab))
        guard seconds > 0 else { return }
        let opened = Date()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .home = self.openView, !self.isHovering,
                  self.lastInteraction <= opened else { return }
            self.openView = nil
        }
        homeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// When the user last clicked or keyed the island; a timed close never cuts that short.
    private var lastInteraction = Date.distantPast

    private static var currentHomeTab: String {
        let stored = UserDefaults.standard.string(forKey: GestureRouter.homeTabKey) ?? GestureRouter.defaultHomeTab
        return GestureRouter.effectiveTab(stored, available: GestureRouter.availableHomeTabs(Preferences.shared))
    }

    private static func selectHomeTab(_ tab: String) {
        guard UserDefaults.standard.string(forKey: GestureRouter.homeTabKey) != tab else { return }
        UserDefaults.standard.set(tab, forKey: GestureRouter.homeTabKey)
    }

    /// Arms the click-outside monitor and the Escape shortcut while something is open, and
    /// disarms both the moment it closes, so neither costs anything at rest.
    private func openStateChanged() {
        lastInteraction = Date()
        if openView != nil {
            HotKeyService.shared.setEscapeArmed(true)
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                // Global monitors only see clicks delivered to other apps, so a click on the
                // island itself (or on our Settings window) never lands here.
                DispatchQueue.main.async { self?.collapse() }
            }
        } else {
            HotKeyService.shared.setEscapeArmed(false)
            if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
            outsideClickMonitor = nil
        }
    }
}

/// A view the user can open on the island and step through with the keyboard.
enum IslandView: Equatable {
    case activity(id: String)
    case home(tab: String)
}
