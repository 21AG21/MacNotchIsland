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
        didSet {
            if openView != oldValue {
                IslandLog.island.notice("open view: \(String(describing: self.openView), privacy: .public)")
            }
            if (openView == nil) != (oldValue == nil) { openStateChanged() }
        }
    }
    /// The panel whose island is being held down, for the press-in feedback.
    @Published private(set) var pressedPanel: String? = nil
    /// Which way the last change of view went: +1 forward, -1 back, 0 for a plain open or
    /// close. Read by the views to pick a push or a cross-fade; not published, since it is
    /// always set right before the change that is.
    private(set) var navigationDirection = 0

    func setNavigationDirection(_ direction: Int) { navigationDirection = direction }
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
    /// Alerts the user clicked open. They live on as activities until closed, so their own
    /// timers cannot pull the panel away.
    private var heldAlertIDs: Set<String> = []
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
        heldAlertIDs.removeAll()
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
    /// Priority below this is ambient (the shelf holding files): it shows when nothing else is
    /// live and otherwise waits in the bubble, however recently it started.
    static let backgroundPriority = 40

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
            let ambientA = a.priority < backgroundPriority, ambientB = b.priority < backgroundPriority
            if ambientA != ambientB { return ambientB }
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
        if openView != nil { IslandLog.island.notice("closing: island hidden") }
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

        // An alert takes the island unless the user has something open; then it is drawn as a
        // strip over the open panel instead (`overlayAlert`), so the panel never goes away.
        if let alert, !isOpen || openView == .activity(id: alert.id) {
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

    /// An alert that arrived while a panel is open (a volume HUD, a battery warning): shown as
    /// the island's compact form over the top of the panel, which stays where it is.
    var overlayAlert: IslandActivity? {
        guard let alert, isOpen, openView != .activity(id: alert.id) else { return nil }
        return alert
    }

    // MARK: - Live activities

    func upsert(_ activity: IslandActivity) {
        if let i = activities.firstIndex(where: { $0.id == activity.id }) {
            var a = activity
            a.startedAt = activities[i].startedAt
            if activities[i] != a { activities[i] = a }
        } else {
            activities.append(activity)
            // The island is about to widen into the menu bar; measure it as it is right now.
            MenuBarClearance.shared.refresh()
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
        heldAlertIDs.remove(id)
        if pinnedID == id { pinnedID = nil }
        if forcedExpandedID == id { forcedExpandedID = nil }
        if openView == .activity(id: id) {
            IslandLog.island.notice("closing: activity \(id, privacy: .public) ended")
            openView = nil
        }
    }

    func end(kind: ActivityKind) {
        for a in activities where a.kind == kind { end(id: a.id) }
    }

    /// Make the bubble activity the primary one (tap on the minimal bubble).
    func promote(id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        pinnedID = id
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

    /// Alerts that wait for an open panel to close rather than interrupt it: everything between
    /// a key-press HUD (feedback the user just asked for) and a battery warning (which cannot
    /// wait). A finished download must not yank away the panel someone is using.
    static func waitsWhileOpen(_ activity: IslandActivity) -> Bool {
        let rank = alertRank(activity)
        return rank >= 3 && rank < 6 && activity.priority < urgentPriority
    }

    /// How long a queued alert stays worth showing: a HUD goes stale in a moment, a finished
    /// download keeps for a while, a battery warning longer still.
    static func patience(for activity: IslandActivity) -> TimeInterval {
        switch alertRank(activity) {
        case ...2: return 2
        case 3...4: return 20
        default: return 90
        }
    }

    func showAlert(_ activity: IslandActivity, duration: TimeInterval? = nil, haptic: Bool = true) {
        let outranked = alert.map { $0.id != activity.id && Self.alertRank($0) > Self.alertRank(activity) } ?? false
        if outranked || (isOpen && Self.waitsWhileOpen(activity)) {
            // Behind the more important alert (a volume tick must not hide a low-battery
            // warning), or until the user closes what they opened.
            enqueue(activity, duration: duration)
            return
        }
        alertWork?.cancel()
        MenuBarClearance.shared.refresh()
        // The user may have opened the alert being replaced; unless a live activity carries the
        // same id (a track-change alert over Now Playing), that view has nothing to show now.
        if let previous = alert, previous.id != activity.id, openView == .activity(id: previous.id),
           self.activity(id: previous.id) == nil {
            IslandLog.island.notice("closing: alert \(previous.id, privacy: .public) replaced")
            openView = nil
        }
        alert = activity
        if haptic { Haptics.tap() }
        scheduleAlertDismiss(id: activity.id, after: duration ?? Preferences.shared.alertDuration)
    }

    private func enqueue(_ activity: IslandActivity, duration: TimeInterval?) {
        pendingAlerts.removeAll { $0.activity.id == activity.id }
        if pendingAlerts.count < 3 { pendingAlerts.append((activity, Date(), duration)) }
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
                // A view opened on this alert closes with it, unless a live activity of the
                // same id is there to carry on.
                if self.openView == .activity(id: id), self.activity(id: id) == nil {
                    IslandLog.island.notice("closing: alert \(id, privacy: .public) expired")
                    self.openView = nil
                }
                self.showNextPendingAlert()
            }
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func showNextPendingAlert() {
        let now = Date()
        pendingAlerts.removeAll { now.timeIntervalSince($0.queuedAt) > Self.patience(for: $0.activity) }
        pendingAlerts.sort { Self.alertRank($0.activity) > Self.alertRank($1.activity) }
        // Whatever is waiting for the panel to close keeps waiting while it is open.
        guard let i = pendingAlerts.firstIndex(where: { !(isOpen && Self.waitsWhileOpen($0.activity)) }) else { return }
        let next = pendingAlerts.remove(at: i)
        showAlert(next.activity, duration: next.duration, haptic: false)
    }

    func dismissAlert() {
        alertWork?.cancel()
        if let alert, openView == .activity(id: alert.id), activity(id: alert.id) == nil { openView = nil }
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
        let shown = presentation(for: panel)
        IslandLog.island.notice("tap on \(panel, privacy: .public): \(shown.contentID, privacy: .public)")
        switch shown {
        case .compact(let a, _):
            if a.content.hasExpandedView, !Self.isTransientHUD(a, alert: alert) {
                open(.activity(id: a.id))
            } else if let action = a.openAction {
                action.perform()
            }
        case .idle:
            open(.home(tab: Self.currentHomeTab))
        case .expanded(let a):
            // Shown because the pointer rests here: a click keeps it after the pointer leaves.
            // Once pinned, clicks on the panel belong to its controls; it closes from outside,
            // the way a popover does: a click anywhere else, Escape, or the shortcut.
            if openView == nil, alert?.id != a.id { open(.activity(id: a.id)) }
        case .home:
            if openView == nil { open(.home(tab: Self.currentHomeTab)) }
        case .shelf:
            break
        }
    }

    /// Whether the panel on `panel` is open because the user asked for it (pointer, click or
    /// keyboard) rather than because an alert took the island. Such a panel carries the view
    /// switcher, so every other view is one click away.
    func isUserPanel(for panel: String?) -> Bool {
        if isOpen { return true }
        let shown = presentation(for: panel)
        guard shown.isExpanded, let alert else { return shown.isExpanded }
        if case .expanded(let a) = shown, a.id == alert.id { return false }
        return true
    }

    /// A key-press HUD (volume, brightness, Caps Lock) is feedback, not a card to open.
    private static func isTransientHUD(_ a: IslandActivity, alert: IslandActivity?) -> Bool {
        alert?.id == a.id && alertRank(a) <= 2
    }

    /// Opens a view and keeps it open until `collapse()`. Model changes made from AppKit
    /// (a click, a hotkey) carry no animation of their own, so the ones that move the island
    /// are wrapped here. No haptic: the trackpad has already clicked under the finger, and a
    /// second click from the app right after reads as a double click.
    func open(_ view: IslandView, direction: Int = 0) {
        homeWork?.cancel()
        lastInteraction = Date()
        navigationDirection = direction
        guard shownView != view else { return }
        withAnimation(direction == 0 ? IslandMotion.open : IslandMotion.navigate) {
            if case .home(let tab) = view { Self.selectHomeTab(tab) }
            if case .activity(let id) = view { holdAlertIfNeeded(id: id) }
            openView = view
        }
    }

    /// An alert the user opens stops being transient: it becomes a live activity that stays
    /// until they close it, so its own timer cannot pull the panel away. An alert that merely
    /// annotates a live activity of the same id (a track change over Now Playing) needs no
    /// promotion; the activity carries on when the alert expires.
    private func holdAlertIfNeeded(id: String) {
        guard let current = alert, current.id == id, activity(id: id) == nil else { return }
        alertWork?.cancel()
        var held = current
        held.expiresAt = nil
        activities.append(held)
        heldAlertIDs.insert(id)
        alert = nil
    }

    /// The global shortcut: close whatever is open, else open the main activity, else Home.
    func toggle() {
        if isOpen || presentation.isExpanded {
            collapse(reason: "shortcut")
        } else if case .compact(let a, _) = presentation, a.content.hasExpandedView, !Self.isTransientHUD(a, alert: alert) {
            open(.activity(id: a.id))
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
        if let current = shownView, let i = ring.firstIndex(of: current) {
            next = ring[(i + (forward ? 1 : ring.count - 1)) % ring.count]
        } else {
            next = forward ? ring[0] : ring[ring.count - 1]
        }
        open(next, direction: forward ? 1 : -1)
    }

    /// Closes whatever is open. `reason` goes to the log, so a panel that closed behind the
    /// user's back can be explained from a report.
    func collapse(reason: String = "request") {
        homeWork?.cancel()
        navigationDirection = 0
        if let current = openView { IslandLog.island.notice("closing \(String(describing: current), privacy: .public): \(reason, privacy: .public)") }
        let held = heldAlertIDs
        heldAlertIDs.removeAll()
        withAnimation(IslandMotion.close) {
            openView = nil
            forcedExpandedID = nil
            for id in held { end(id: id) }
            if !isHovering, alert != nil {
                alertWork?.cancel()
                alert = nil
            }
        }
        // Anything that waited for the panel to close gets its turn now.
        if alert == nil { showNextPendingAlert() }
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

    /// When the user last clicked or keyed the island; a timed close never cuts that short,
    /// and neither does anything that arrives in the tail of the very click that opened it.
    private(set) var lastInteraction = Date.distantPast

    /// Whether a screen point lies on an island; set by the app delegate from its panels.
    var islandHitTest: ((NSPoint) -> Bool)?

    /// `openView` as the user sees it. A tab picked in the tab bar or by a swipe changes the
    /// stored tab without going through `open`, so the Home case is re-read from the store.
    private var shownView: IslandView? {
        if case .home = openView { return .home(tab: Self.currentHomeTab) }
        return openView
    }

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
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                let type = event.type.rawValue
                let window = event.windowNumber
                DispatchQueue.main.async { self?.clickedElsewhere(type: type, window: window) }
            }
        } else {
            HotKeyService.shared.setEscapeArmed(false)
            if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
            outsideClickMonitor = nil
        }
    }
}

extension ActivityCenter {
    /// A mouse-down the system delivered to another application while something is open.
    /// Global monitors are documented not to see our own clicks, but nothing here relies on
    /// that: the click must be past the opening click's tail and land off the island.
    fileprivate func clickedElsewhere(type: UInt, window: Int) {
        guard openView != nil else { return }
        let location = NSEvent.mouseLocation
        let sinceInteraction = Date().timeIntervalSince(lastInteraction)
        let onIsland = islandHitTest?(location) ?? false
        IslandLog.island.notice("mouse-down elsewhere: type \(type, privacy: .public) window \(window, privacy: .public) at \(Double(location.x), privacy: .public),\(Double(location.y), privacy: .public) onIsland \(onIsland, privacy: .public) after \(sinceInteraction, privacy: .public)s")
        guard sinceInteraction > 0.4, !onIsland else { return }
        collapse(reason: "click outside")
    }
}

/// A view the user can open on the island and step through with the keyboard.
enum IslandView: Equatable {
    case activity(id: String)
    case home(tab: String)
}
