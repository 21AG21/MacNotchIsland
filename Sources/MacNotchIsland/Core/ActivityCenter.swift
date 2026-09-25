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
                // A find belongs to the list it was typed into; stepping to the next section
                // starts again rather than carrying somebody's search somewhere it means
                // nothing. Set before the keys are settled, which read it.
                findQuery = nil
                findIndex = 0
                // A close of any kind — a card's Stop, an alert replaced, a timed Home —
                // forgets which way the last step went. `collapse` did; the other closes
                // left the step in place, and the next open grew on the navigate spring and
                // slid in from the side. The keyboard invitation ends with the panel too.
                if openView == nil {
                    navigationDirection = 0
                    keyboardInvited = false
                }
                // Every change, not only opening and closing: the keys the panel answers
                // depend on which section it is on.
                keyboardControlChanged()
            }
            if (openView == nil) != (oldValue == nil) { openStateChanged() }
        }
    }
    /// The island the open view was opened on, when it was opened from one — a click or a
    /// press on that island. Nil when it was opened from everywhere at once (the shortcut,
    /// the menu bar, a URL), and then every island shows it. With an island on every
    /// display, a click on one used to expand all of them.
    @Published private(set) var openPanel: String? = nil
    /// The view the panel shows while it is only under the pointer. Seeded from what the
    /// island was showing when the pointer arrived; the switcher, a swipe or Tab move it. A
    /// click promotes it to `openView` as is.
    @Published private(set) var peekView: IslandView? = nil
    /// The panel whose island is being held down, for the press-in feedback.
    @Published private(set) var pressedPanel: String? = nil
    /// Which way the last change of view went: +1 forward, -1 back, 0 for a plain open or
    /// close. Read by the views to pick a push or a cross-fade; not published, since it is
    /// always set right before the change that is.
    private(set) var navigationDirection = 0
    @Published private(set) var forcedExpandedID: String? = nil
    @Published private(set) var pinnedID: String? = nil
    @Published var micInUse = false
    @Published var cameraInUse = false
    /// The islands whose display a full-screen app covers, while the user asked to hide
    /// there. Per display: a film on the external display hides that display's island and
    /// leaves the MacBook's alone, and the other way about.
    @Published var fullscreenPanels: Set<String> = []
    /// The islands that exist right now, told by the app delegate whenever it builds them.
    /// What is asked about no island in particular is answered for these.
    @Published private(set) var livePanels: Set<String> = []
    /// True while every island there is hides under a full-screen app. Not any: a film on
    /// the external display used to count as the MacBook's island being hidden, and the
    /// shortcut, the menu bar and the URL scheme opened nothing while it played.
    var fullscreenSuppressed: Bool {
        Self.allHidden(live: livePanels, covered: fullscreenPanels)
    }

    static func allHidden(live: Set<String>, covered: Set<String>) -> Bool {
        live.isEmpty ? !covered.isEmpty : live.isSubset(of: covered)
    }

    /// The panels were built again: these are the islands now. A view opened on an island
    /// that is gone is opened everywhere, rather than drawn nowhere with Escape armed.
    func panelsRebuilt(_ panels: Set<String>) {
        livePanels = panels
        if let openPanel, !panels.contains(openPanel) { self.openPanel = nil }
    }
    /// True while an app the user listed under "hide for these apps" is frontmost.
    @Published var appSuppressed = false

    /// Nothing is drawn while suppressed: a pause, a hidden app, or a full-screen app on any
    /// display. What is asked without naming a panel answers for all of them; a panel asks
    /// `isSuppressed(panel:)` about its own display.
    var isSuppressed: Bool { isSuppressed(panel: nil) }

    func isSuppressed(panel: String?) -> Bool {
        if appSuppressed { return true }
        if let panel {
            if fullscreenPanels.contains(panel) { return true }
        } else if fullscreenSuppressed {
            return true
        }
        let until = Preferences.shared.pausedUntil
        return until > 0 && Date().timeIntervalSince1970 < until
    }

    private var alertWork: DispatchWorkItem?
    private var pendingAlerts: [(activity: IslandActivity, queuedAt: Date, duration: TimeInterval?, exact: Bool)] = []
    /// Alerts the user clicked open. They live on as activities until closed, so their own
    /// timers cannot pull the panel away.
    private var heldAlertIDs: Set<String> = []
    /// True while a slider or the scrubber is being dragged, see `setControlDragging`.
    private(set) var controlDragging = false
    /// A hover exit that arrived mid-drag and is waiting for the button to come up.
    private var deferredHoverExit: String?
    /// The hover request on the timer, so the same request again is left to run rather than
    /// re-armed: the panel reports the pointer's every move, and a grace period that starts
    /// over on each of them never runs out while the pointer is moving.
    private var pendingHover: (hovering: Bool, panel: String)?
    /// An island whose panel was closed while the pointer was resting on it. It shows no peek
    /// until the pointer has left and come back: closing with the pointer on the panel used
    /// to close nothing, since the peek branch drew the same panel again at once.
    private var peekSuppressed: String?
    /// Whether the keyboard was asked for — by any open but the one a click on a control in
    /// a peek makes. That click pins the panel but is not an invitation: the hand that
    /// clicked pause in a peek while typing in Pages is going back to Pages, and the island
    /// taking the keyboard on that click sent every letter after it into nothing.
    private(set) var keyboardInvited = false {
        didSet { if keyboardInvited != oldValue { objectWillChange.send(); keyboardControlChanged() } }
    }
    /// When the panel last opened, for the guards against the tail of the click that opened
    /// it. Not `lastInteraction`, which every slider and every step moves as well: a click
    /// outside right after letting go of the volume slider was taken for that tail, and
    /// ignored.
    private(set) var openedAt = Date.distantPast
    private var hoverWork: DispatchWorkItem?
    /// The pending "the drag has left" — see `setDragTargeted`.
    private var dragExitWork: DispatchWorkItem?
    private var homeWork: DispatchWorkItem?
    private var forcedWork: DispatchWorkItem?
    /// Watches for clicks outside the island while it is open, the way a transient popover does.
    private var outsideClickMonitor: Any?
    /// Watches for another app coming forward while it is open. A click outside is not the only
    /// way to leave: Command-Tab never sends one.
    private var activationObserver: Any?
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
        controlDragging = false
        deferredHoverExit = nil
        dragExitWork?.cancel()
        dragExitWork = nil
        openView = nil
        openPanel = nil
        peekView = nil
        fullscreenPanels = []
        livePanels = []
        lastSpaceChange = .distantPast
        pendingHover = nil
        peekSuppressed = nil
        keyboardInvited = false
        openedAt = .distantPast
        findQuery = nil
        findIndex = 0
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
        forgetPointer()
        if openView != nil { IslandLog.island.notice("closing: island hidden") }
        openView = nil
        openPanel = nil
    }

    /// Nothing the pointer was doing on an island is true any longer — the panels are being
    /// torn down and built again. SwiftUI never reports a hover ending on a window that
    /// closed, so without this the island stayed "hovered" by a window that no longer
    /// existed: the shortcut found a panel showing and closed nothing, the keys stepped an
    /// invisible peek, the sneak peeks kept quiet — until the pointer happened to cross the
    /// new island. What was opened by a click stays open; only the pointer is forgotten.
    func forgetPointer() {
        hoverWork?.cancel()
        hoverWork = nil
        pendingHover = nil
        peekSuppressed = nil
        dragExitWork?.cancel()
        dragExitWork = nil
        deferredHoverExit = nil
        controlDragging = false
        if hoverPanel != nil { hoverPanel = nil }
        if dragPanel != nil { dragPanel = nil }
        if pressedPanel != nil { pressedPanel = nil }
        if openView == nil, peekView != nil { peekView = nil }
        navigationDirection = 0
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

        // A drag means the shelf everywhere but the two sections whose own content takes one:
        // the shelf's well would cover their tiles before a file could reach one. A file
        // dropped anywhere else on the island still goes to the shelf.
        // The section on screen, pinned or peeked. Asking only about the pinned one meant a
        // drag over a peeked Actions row turned it into the shelf's well and hid the very
        // tiles the file was being carried to.
        let sectionTakesDrops = shownSection.map { Self.dropTargetSections.contains($0) } ?? false
        if dragging && prefs.shelfEnabled && !sectionTakesDrops { return .shelf }

        let peeking = hovering && prefs.hoverToExpand
        // An alert takes the island unless a panel is showing; then it is drawn over the panel
        // instead (`overlayAlert`), so the panel never goes away under the user. A panel that
        // is only under the pointer does yield to a battery warning.
        // Open on this island, not merely open: a panel pinned on the other display leaves
        // this one free to show the alert.
        let openHere = openView != nil && Self.shows(openPanel: openPanel, on: panel)
        if let alert, !openHere, !peeking || Self.alertRank(alert) >= 6 {
            let large = alert.presentation == .expanded || (hovering && prefs.hoverToExpand && Self.alertRank(alert) > 2)
            if large && alert.content.hasExpandedView { return .card(alert) }
            // A key-press HUD over a live activity keeps that activity's glyph on the left
            // (`IslandLayout.activityUnder`) — and its bubble, which used to pop out and back
            // on every press of the volume key.
            let under = IslandLayout.activityUnder(alert, center: self)
            return .compact(alert, bubble: under == nil ? nil : sortedActivities.dropFirst().first)
        }

        if let view = openView, Self.shows(openPanel: openPanel, on: panel) { return .panel(validated(view)) }

        let live = sortedActivities
        if let primary = live.first, forcedExpandedID == primary.id, primary.content.hasExpandedView {
            return .card(primary)
        }
        if peeking, hoverPeeks { return .panel(validated(peekView ?? defaultPeek())) }
        if let primary = live.first {
            return .compact(primary, bubble: live.dropFirst().first)
        }
        return .idle
    }

    /// Whether the open view belongs on `panel`: everywhere when it was opened from
    /// everywhere, else only on the island it was opened on. Asked without a panel, it is
    /// open.
    static func shows(openPanel: String?, on panel: String?) -> Bool {
        guard let openPanel, let panel else { return true }
        return openPanel == panel
    }

    func activity(id: String) -> IslandActivity? { activities.first { $0.id == id } }

    /// True while the user's panel is on screen, pinned or under the pointer.
    var isPanelShowing: Bool {
        isOpen || (hoverPanel != nil && Preferences.shared.hoverToExpand)
    }

    /// An alert that arrived while the panel is showing (a volume HUD, a finished download, a
    /// battery warning): drawn over the panel, which stays where it is. The one exception is a
    /// battery warning over a panel that is merely under the pointer: that takes the island.
    var overlayAlert: IslandActivity? {
        guard let alert, isPanelShowing else { return nil }
        if !isOpen, Self.alertRank(alert) >= 6 { return nil }
        return alert
    }

    /// The view a panel opened for `activity` shows: a Now Playing or shelf pill opens its
    /// Home section; anything else opens its own card in the panel.
    static func view(for activity: IslandActivity) -> IslandView {
        switch activity.kind {
        case .nowPlaying: return .home(tab: HomeSection.music.rawValue)
        case .shelf: return .home(tab: HomeSection.shelf.rawValue)
        default: return .activity(id: activity.id)
        }
    }

    /// What the pointer opens: the panel on whatever the island is showing, else Home.
    func defaultPeek() -> IslandView {
        if let primary = sortedActivities.first {
            if primary.kind == .nowPlaying || primary.kind == .shelf { return Self.view(for: primary) }
            if primary.content.hasExpandedView { return .activity(id: primary.id) }
        }
        return .home(tab: Self.currentHomeTab)
    }

    /// Whether resting the pointer on the island should open anything.
    ///
    /// With something live there is always something to peek at. On the bare notch there is
    /// not, and whether it opens the panel anyway is the user's to say — "Open from the empty
    /// notch too", in the Island pane. That switch had been sitting there with its reader
    /// deleted out from under it, promising to gate something that happened either way.
    ///
    /// The keyboard shortcut is deliberately not asked: somebody who presses it has said what
    /// they want, and this is only about what the pointer does when it happens to pass by.
    var hoverPeeks: Bool {
        Self.peeksWhenIdle(hasLiveActivity: !sortedActivities.isEmpty,
                           idleHover: Preferences.shared.expandOnIdleHover)
    }

    /// The rule on its own, so it can be read back without a pointer to rest on the notch.
    static func peeksWhenIdle(hasLiveActivity: Bool, idleHover: Bool) -> Bool {
        hasLiveActivity || idleHover
    }

    /// A view the panel can actually show: an activity that is still live and has a card, or
    /// a Home section that is switched on (the nearest one, if the asked-for one is not).
    func validated(_ view: IslandView) -> IslandView {
        switch view {
        case .activity(let id):
            if let a = activity(id: id) {
                if a.kind == .nowPlaying || a.kind == .shelf { return Self.view(for: a) }
                if a.content.hasExpandedView { return view }
            }
            return .home(tab: Self.currentHomeTab)
        case .home(let tab):
            return .home(tab: HomeSection.resolve(tab, prefs: Preferences.shared).rawValue)
        }
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

    func end(id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        activities.removeAll { $0.id == id }
        heldAlertIDs.remove(id)
        if pinnedID == id { pinnedID = nil }
        if forcedExpandedID == id { forcedExpandedID = nil }
        if openView == .activity(id: id) {
            IslandLog.island.notice("closing: activity \(id, privacy: .public) ended")
            closedUnderPointer()
            openView = nil
            openPanel = nil
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
        case .nowPlaying: return 3
        case .focus, .unlock: return 3
        case .download, .bluetooth, .drive: return 4
        case .battery(let b): return (b.event == .low || b.event == .critical) ? 6 : 5
        default: return 3
        }
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

    /// Whether a Focus holds this alert back.
    ///
    /// Only the ones that arrive on their own: something finished downloading, a device
    /// connected, an event is coming up, a script pushed one through the URL scheme, the
    /// charger went in. Anything the person just did — a key, a click, a screenshot, a
    /// shortcut they ran — is not an interruption and is never held, whatever else is on.
    /// A battery that is nearly flat is not held either: a Focus is a request not to be
    /// disturbed, not a request to be allowed to run out.
    static func focusHolds(_ activity: IslandActivity) -> Bool {
        switch activity.content {
        case .download, .bluetooth, .calendar: return true
        // A disk arriving is held; a disk that has gone is not. "Safe to unplug" is the
        // answer to something the person is doing with their hands right now, and the
        // warning that one was pulled out early is the one thing a Focus must not swallow.
        case .drive(let d): return d.event == .connected
        case .battery(let b): return !(b.event == .low || b.event == .critical)
        case .custom: return activity.id.hasPrefix("api-")
        default: return false
        }
    }

    /// Whether the island is quietening itself at this moment.
    private var focusIsQuiet: Bool {
        let p = Preferences.shared
        return p.quietDuringFocus && p.focusEnabled && FocusMonitor.isOn
    }

    /// The figure the "Alert duration" slider ships at, which is the length an alert with no
    /// length of its own is shown for. It has to agree with the default in `Preferences`;
    /// it is the one point on the slider where every alert is exactly as long as its caller
    /// asked for.
    static let standardAlertDuration: TimeInterval = 1.8

    /// How long an alert stays up, from what its caller asked for and where the slider is.
    ///
    /// The slider used to be nothing more than the fallback for a caller that named no
    /// length, and nearly every caller names one — a copied line a second, a HUD a moment
    /// and a half, a finished download four — so dragging it to six changed nothing anybody
    /// could see. It is a scale now: the figure on it is what an alert with no length of its
    /// own gets, and every other alert keeps its own proportion to that, so twice the
    /// shipping figure is twice as long for all of them and half is half. A scale rather than
    /// a floor because the callers' figures are the only thing that says a copied line is
    /// briefer than a download, and a floor would flatten that the moment it was raised — and
    /// would lengthen the shipping app's own alerts before the slider had been touched.
    static func alertDuration(requested: TimeInterval?, preference: TimeInterval) -> TimeInterval {
        // A hand-edited defaults entry of nought or less would dismiss everything on arrival.
        guard preference.isFinite, preference > 0 else { return requested ?? standardAlertDuration }
        guard let requested else { return preference }
        // The ratio first, so that at the shipping figure it is exactly one and every caller
        // gets exactly what it asked for, to the last bit.
        return requested * (preference / standardAlertDuration)
    }

    /// `exact` takes `duration` as it is, unscaled by the alert-duration setting: a script
    /// that asked for three seconds gets three, whatever the slider says.
    func showAlert(_ activity: IslandActivity, duration: TimeInterval? = nil, exact: Bool = false, haptic: Bool = true) {
        if focusIsQuiet, Self.focusHolds(activity) {
            IslandLog.island.notice("focus holds \(activity.id, privacy: .public)")
            return
        }
        let outranked = alert.map { $0.id != activity.id && Self.alertRank($0) > Self.alertRank(activity) } ?? false
        if outranked {
            // Behind the more important alert: a volume tick must not hide a low-battery warning.
            // It keeps its exact duration for when its turn comes.
            enqueue(activity, duration: duration, exact: exact)
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
        // A louder alert replacing a quieter one keeps the quieter one for afterwards, so a
        // battery warning never makes a finished download vanish unseen. Key-press HUDs are
        // stale by then and are not kept.
        if let previous = alert, previous.id != activity.id,
           Self.alertRank(previous) >= 3, Self.alertRank(previous) < Self.alertRank(activity) {
            enqueue(previous, duration: nil)
        }
        alert = activity
        if haptic { Haptics.tap() }
        let seconds = exact ? (duration ?? Self.standardAlertDuration)
                            : Self.alertDuration(requested: duration, preference: Preferences.shared.alertDuration)
        scheduleAlertDismiss(id: activity.id, after: seconds)
    }

    private func enqueue(_ activity: IslandActivity, duration: TimeInterval?, exact: Bool = false) {
        pendingAlerts.removeAll { $0.activity.id == activity.id }
        if pendingAlerts.count < 3 { pendingAlerts.append((activity, Date(), duration, exact)) }
    }

    private func scheduleAlertDismiss(id: String, after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.alert?.id == id else { return }
            // Keep a real alert up while the pointer is on it, like holding a finger on the island;
            // very short confirmations ("Copied") expire regardless, since a click leaves the pointer
            // there, and so does a banner over the panel, whose rail the pointer is there to use.
            if (self.isHovering || self.isDragTargeted) && seconds > 1.5 && !self.isPanelShowing {
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
        guard !pendingAlerts.isEmpty else { return }
        let next = pendingAlerts.removeFirst()
        showAlert(next.activity, duration: next.duration, exact: next.exact, haptic: false)
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
    /// The pointer arrived on or left the island. Arrival waits the hover delay, so a pointer
    /// crossing the notch on its way to the clock opens nothing; departure waits a grace
    /// period, so a slip off the panel's edge does not close it.
    func setHovering(_ hovering: Bool, panel: String = "main") {
        // The same request again, while the first is still on the timer, is that request.
        if let pending = pendingHover, pending.hovering == hovering, pending.panel == panel { return }
        hoverWork?.cancel()
        pendingHover = (hovering, panel)
        let delay = hovering ? Preferences.shared.hoverDelay : Self.hoverExitGrace
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHover = nil
            if hovering {
                deferredHoverExit = nil
                guard self.hoverPanel != panel, self.peekSuppressed != panel else { return }
                if self.peekView == nil, self.hoverPeeks { self.peekView = self.defaultPeek() }
                self.hoverPanel = panel
            } else {
                if self.peekSuppressed == panel { self.peekSuppressed = nil }
                guard self.hoverPanel == panel else { return }
                // A slider or the scrubber being dragged keeps the panel: the pointer is
                // allowed to run past the end of the track, the way it may on a menu bar
                // slider. The exit is applied the moment the button comes up.
                guard !self.controlDragging else {
                    self.deferredHoverExit = panel
                    return
                }
                self.hoverPanel = nil
                if self.openView == nil { self.peekView = nil }
                // Forget which way the last step went. Only `open` and `collapse` used to
                // clear this, and a hover exit goes through neither — so after ever stepping
                // sideways in a peeked panel, every hover-open afterwards grew on the flat
                // navigate spring instead of the open one, and its content slid in from the
                // side instead of crossing over. It healed only when something was clicked,
                // which is why opening the same panel twice could look like two apps.
                self.navigationDirection = 0
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A control inside the panel is being dragged. Nothing about the pointer leaving the
    /// island may close it until the drag is over.
    func setControlDragging(_ active: Bool, panel: String = "main") {
        guard controlDragging != active else { return }
        controlDragging = active
        lastInteraction = Date()
        guard !active, let deferred = deferredHoverExit else { return }
        deferredHoverExit = nil
        // Straight away, not after another grace period: the pointer left a while ago.
        hoverWork?.cancel()
        pendingHover = nil
        guard hoverPanel == deferred else { return }
        hoverPanel = nil
        if openView == nil { peekView = nil }
    }

    static let hoverExitGrace: TimeInterval = 0.4

    /// Press-in feedback: the island shrinks slightly under the pointer, like the iPhone's
    /// island under a finger.
    func setPressed(_ pressed: Bool, panel: String = "main") {
        let next: String? = pressed ? panel : nil
        if pressedPanel != next { pressedPanel = next }
        if pressed { pinPeek(panel: panel) }
    }

    /// A click anywhere in a panel that is only under the pointer pins it.
    ///
    /// The island's own tap gesture does this for a click on its background, but a click that
    /// lands on a control — a slider, the output menu, a rail button — is consumed by that
    /// control and never reaches it. Without this, using one of those controls left the panel
    /// unpinned, and it would vanish the moment the pointer followed a menu off the island.
    /// The press is enough: the user has committed to the panel.
    func pinPeek(panel: String) {
        guard !openHere(panel), hoverPanel == panel, Preferences.shared.hoverToExpand,
              case .panel(let view) = presentation(for: panel) else { return }
        open(view, panel: panel, invitesKeyboard: false)
    }

    /// How long the island goes on counting as a drop target after the drag appears to leave
    /// it. Short enough to be invisible, long enough to cover the gap.
    static let dragExitGrace: TimeInterval = 0.25

    func setDragTargeted(_ targeted: Bool, panel: String = "main") {
        if targeted {
            dragExitWork?.cancel()
            dragExitWork = nil
            guard dragPanel != panel else { return }
            // Animated: a panel that is open goes to the shelf's well and back, and a change
            // with no animation of its own tore the whole panel down and built it again.
            withAnimation(IslandMotion.fade) { dragPanel = panel }
            Haptics.tap()
        } else {
            guard dragPanel == panel || panel == "main" else { return }
            // Every drop target inside the island — a quick action's tile, a window's tile, a
            // slot of the switcher — takes the drag off the island's own target for as long as
            // the pointer is over it, and the island is told the drag has left. So leaving is
            // deferred: a drag that comes back within a moment never left, and the shelf's
            // well does not blink out from under the hand that is over it.
            scheduleDragExit()
        }
    }

    /// An inner drop target has the drag — a slot of the switcher, a quick action's tile — so
    /// the island is not to count as having lost it. Panel-agnostic on purpose: the inner view
    /// does not know which display's island it is part of, only that the drag is on it.
    func holdDrag(_ held: Bool) {
        if held {
            dragExitWork?.cancel()
            dragExitWork = nil
        } else if dragPanel != nil {
            scheduleDragExit()
        }
    }

    private func scheduleDragExit() {
        dragExitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dragExitWork = nil
            withAnimation(IslandMotion.fade) { self?.dragPanel = nil }
        }
        dragExitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragExitGrace, execute: work)
    }

    /// A click on the island. Compact: open what is showing. Expanded: close it again, the way a
    /// menu bar extra toggles. Idle: open the Home panel. Alerts without a large view perform
    /// their action instead.
    func tap(panel: String = "main") {
        let shown = presentation(for: panel)
        IslandLog.island.notice("tap on \(panel, privacy: .public): \(shown.contentID, privacy: .public)")
        switch shown {
        case .compact(let a, _):
            guard !Self.isTransientHUD(a, alert: alert) else { return }
            if a.content.hasExpandedView {
                open(Self.view(for: a), panel: panel)
            } else if let action = a.openAction {
                action.perform()
            }
        case .card(let a):
            // A click on a system card keeps it: it becomes the panel's current view.
            if !Self.isTransientHUD(a, alert: alert) { open(Self.view(for: a), panel: panel) }
        case .idle:
            open(.home(tab: Self.currentHomeTab), panel: panel)
        case .panel(let view):
            // Shown because the pointer rests here: a click keeps it after the pointer leaves.
            // Once pinned, clicks on the panel belong to its controls; it closes from outside,
            // the way a popover does: a click anywhere else, Escape, or the shortcut. A panel
            // pinned on another display's island is not pinned here.
            if !openHere(panel) { open(view, panel: panel) }
        case .shelf:
            break
        }
        // Only a click that left something open has asked for the keyboard; one on a
        // key-press HUD, or on a card that performs an action, opened nothing.
        if isOpen { keyboardInvited = true }
    }

    /// Whether the open view is open on `panel` — pinned there, or everywhere.
    func openHere(_ panel: String?) -> Bool {
        openView != nil && Self.shows(openPanel: openPanel, on: panel)
    }

    /// A key-press HUD (volume, brightness, Caps Lock) is feedback, not a card to open.
    private static func isTransientHUD(_ a: IslandActivity, alert: IslandActivity?) -> Bool {
        alert?.id == a.id && alertRank(a) <= 2
    }

    /// Opens a view and keeps it open until `collapse()`. Model changes made from AppKit
    /// (a click, a hotkey) carry no animation of their own, so the ones that move the island
    /// are wrapped here. No haptic: the trackpad has already clicked under the finger, and a
    /// second click from the app right after reads as a double click.
    ///
    /// `panel` is the island it was opened on, for a click or a press; a step from the
    /// keyboard names none and stays wherever the panel already is, and an open from the
    /// shortcut or the menu bar, with nothing open, is for every island. Every open asks
    /// for the keyboard except the one a click on a control makes (`pinPeek`).
    func open(_ view: IslandView, direction: Int = 0, panel: String? = nil, invitesKeyboard: Bool = true) {
        homeWork?.cancel()
        lastInteraction = Date()
        navigationDirection = direction
        if case .activity(let id) = view { holdAlertIfNeeded(id: id) }
        let target = validated(view)
        let island = panel ?? (openView != nil ? openPanel : nil)
        // A hidden island opens nothing. The shortcut opened an invisible panel over a
        // full-screen film, and its keys were claimed system-wide with nothing to show for
        // them until Escape.
        guard !isSuppressed(panel: island) else { return }
        if invitesKeyboard { keyboardInvited = true }
        guard openView != target else {
            // The same view, asked for from a second island: it shows on both.
            if openPanel != island { openPanel = nil }
            return
        }
        withAnimation(direction == 0 ? IslandMotion.open : IslandMotion.navigate) {
            if case .home(let tab) = target { Self.selectHomeTab(tab) }
            peekView = nil
            openPanel = island
            openView = target
        }
    }

    /// Shows `view` in the panel: pinned if the panel is pinned, under the pointer if it is
    /// only peeking, and opened outright when nothing is showing (a keyboard step).
    func select(_ view: IslandView, direction: Int = 0, panel: String? = nil) {
        // Opened here, or nothing to peek on: an open. Peeking here while the panel is
        // pinned on another display's island: the peek steps, and that panel stays.
        if openHere(panel ?? hoverPanel) || hoverPanel == nil || !Preferences.shared.hoverToExpand {
            open(view, direction: direction, panel: panel)
            return
        }
        guard !isSuppressed(panel: hoverPanel) else { return }
        lastInteraction = Date()
        navigationDirection = direction
        let target = validated(view)
        guard peekView != target else { return }
        withAnimation(direction == 0 ? IslandMotion.open : IslandMotion.navigate) {
            if case .home(let tab) = target { Self.selectHomeTab(tab) }
            peekView = target
        }
    }

    /// Straight to one slot of the switcher, the way the digit keys do it. A digit past the
    /// end of the ring — a 7 where there are five slots — does nothing, rather than landing
    /// somewhere arbitrary. Returns false when there was no such slot.
    @discardableResult
    func selectSlot(_ index: Int) -> Bool {
        let ring = self.ring
        guard ring.indices.contains(index) else { return false }
        let target = ring[index]
        guard target != currentView else { return true }
        // The disc travels the way you are going, the same as a step or a swipe.
        let here = currentView.flatMap { ring.firstIndex(of: $0) } ?? 0
        select(target, direction: index > here ? 1 : -1)
        return true
    }

    /// Sections whose own tiles are drop targets: a quick action runs a shortcut with what
    /// you drop on it, a window tile opens what you drop on it with that app.
    static let dropTargetSections: Set<HomeSection> = [.actions, .windows]

    /// The section on screen, whether the panel is pinned open or only under the pointer.
    /// What the user is looking at, as opposed to what they have committed to.
    var shownSection: HomeSection? {
        guard case .home(let tab)? = currentView else { return nil }
        return HomeSection(rawValue: tab)
    }

    /// The section the panel is pinned on, if it is pinned on one. Not the peek: a peek
    /// follows the pointer, and during a drag the pointer is holding something.
    var openSection: HomeSection? {
        guard case .home(let tab)? = openView else { return nil }
        return HomeSection(rawValue: tab)
    }

    /// Whether the panel is open on the Shelf section at this moment. Space means Quick Look
    /// there, the way it does in Finder, rather than play and pause.
    var isShowingShelf: Bool {
        guard case .home(let tab)? = currentView else { return false }
        return HomeSection(rawValue: tab) == .shelf
    }

    /// What has been typed into the panel's find field, or nil when nobody is searching.
    /// Published so the section showing can narrow to it and the field can draw itself.
    @Published private(set) var findQuery: String? = nil

    /// Which of the matches the find is pointing at, counting from zero. Typing starts again
    /// at the top; the arrow keys walk it, and Return takes whatever it is on.
    @Published private(set) var findIndex = 0

    /// Moves the find's mark by a row, wrapping at both ends the way a menu does.
    func moveFind(by delta: Int, count: Int) {
        guard findQuery != nil, count > 0 else { return }
        findIndex = Self.wrapped(findIndex + delta, count: count)
    }

    /// Pure: an index brought back inside a list of `count` by wrapping round it.
    static func wrapped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    /// The row the find is on, given how many there actually are — nil when nobody is finding
    /// or there is nothing to point at. A list that shrinks under the mark brings it back to
    /// the last row rather than pointing past the end.
    func findTarget(of count: Int) -> Int? {
        guard findQuery != nil, count > 0 else { return nil }
        return min(findIndex, count - 1)
    }

    /// Start a find with the letter that was just pressed. The panel has to be pinned open on
    /// a section that is a list of things — anywhere else the letters were never claimed, so
    /// this is never reached — and anything but a letter is left alone.
    func beginFind(with character: String) {
        guard PanelFind.opensFind(character), PanelFind.searches(openSection) else { return }
        lastInteraction = Date()
        IslandLog.keys.notice("find opened by a key press")
        findIndex = 0
        withAnimation(IslandMotion.content) { findQuery = character }
        keyboardControlChanged()
    }

    /// Open the field with nothing in it: the magnifying glass in a section's header, clicked.
    func beginFind() {
        guard PanelFind.searches(openSection), findQuery == nil else { return }
        lastInteraction = Date()
        findIndex = 0
        withAnimation(IslandMotion.content) { findQuery = "" }
        keyboardControlChanged()
    }

    /// What the field types into.
    func updateFind(_ text: String) {
        guard findQuery != nil else { return }
        // Every keystroke narrows the list under the mark, so the mark goes back to the top:
        // pointing at the fourth of two rows is not somewhere anybody asked to be.
        findIndex = 0
        findQuery = text
    }

    /// Leave the find, keeping the panel where it is. Returns false when there was no find to
    /// leave, which is how Escape knows to close the panel instead.
    @discardableResult
    func endFind() -> Bool {
        guard findQuery != nil else { return false }
        lastInteraction = Date()
        findIndex = 0
        withAnimation(IslandMotion.content) { findQuery = nil }
        keyboardControlChanged()
        return true
    }

    /// Whether one of the island's own windows is the key window right now.
    ///
    /// The panel's keys are global hot keys — Carbon hands them here instead of to whoever was
    /// typing — so the question of whether they may be claimed is really the question of whether
    /// the keyboard is already ours. Key status is the system's own answer to that, and the only
    /// one nobody has to guess at.
    @Published private(set) var holdsKeyboard = false

    /// A panel became or stopped being the key window.
    ///
    /// Asked again on the next turn rather than answered here: at the moment `resignKey` runs
    /// the window has not stopped being key yet, and with an island on several screens the
    /// question is about all of them together, not the one that spoke.
    func panelKeyChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let holds = NSApp.windows.contains { ($0 as? NotchPanel)?.isKeyWindow == true }
            guard holds != self.holdsKeyboard else { return }
            self.holdsKeyboard = holds
            self.keyboardControlChanged()
        }
    }

    /// Whether the island should be holding the keyboard at all.
    ///
    /// A pinned panel takes it, which is the change that makes its keys honest: until it did,
    /// clicking the island left the app behind frontmost with the insertion point still in
    /// somebody's half-written reply, and the letters they typed next were taken out of it.
    /// Taking key status is visible — the window behind dims its focus — so somebody can see
    /// where their typing is going, which is the whole difference between a claim and a theft.
    /// A peek takes nothing: the pointer is only passing over.
    var wantsPanelKeyboard: Bool {
        // A hidden island has nothing to type into.
        if isSuppressed(panel: openPanel) { return false }
        if wantsKeyboard { return true }
        return openView != nil && keyboardInvited && Preferences.shared.panelKeysEnabled
    }

    /// Re-reads whether the panel's own keys should be claimed. Called when the panel moves
    /// and when a preference changes.
    func refreshPanelKeys() { keyboardControlChanged() }

    /// Whether the digits and the arrows are the island's at this moment. The switcher shows
    /// a slot's number beside its name while they are, which is where somebody is looking
    /// when they want to know how to get to it.
    var panelKeysActive: Bool { currentClaim.bareKeys }

    /// What the island may take from the keyboard as things stand.
    private var currentClaim: HotKeyService.KeyClaim {
        HotKeyService.claim(pinnedOpen: openView != nil,
                            holdsKeyboard: holdsKeyboard,
                            textFieldUp: wantsKeyboard,
                            listSection: PanelFind.searches(openSection),
                            enabled: Preferences.shared.panelKeysEnabled)
    }

    private func keyboardControlChanged() {
        HotKeyService.shared.setPanelKeys(currentClaim)
        HotKeyService.shared.setEscapeArmed(escapeArmed)
    }

    /// Escape closes the panel from anywhere, as a global key — except while another of this
    /// app's own windows has the keyboard. Quick Look opened from the shelf, or Settings from
    /// the rail, took the key from the panel: the island closed and the window the key was
    /// meant for stayed, and a second Escape was needed.
    private var escapeArmed: Bool {
        guard openView != nil else { return false }
        let windows = (NSApp?.windows ?? []).map { (isKey: $0.isKeyWindow, isPanel: $0 is NotchPanel) }
        return !PanelKeyboard.heldByAnotherOfOurs(windows)
    }

    /// Key status moving between this app's own windows re-reads `escapeArmed`. Armed only
    /// while something is open, like the click-outside monitor.
    private var keyWindowObservers: [NSObjectProtocol] = []

    private func watchOurOwnWindows() {
        guard keyWindowObservers.isEmpty else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A turn later, as `panelKeyChanged` reads it: inside the notification the
                // resigning window still says it is key.
                DispatchQueue.main.async { self?.keyboardControlChanged() }
            })
        }
    }

    /// One step along the ring. Without `wrap` the ends are ends (a swipe is spatial); with it
    /// the ring is a cycle (Tab). Returns false when there was nowhere to go.
    @discardableResult
    func step(forward: Bool, wrap: Bool) -> Bool {
        let ring = self.ring
        guard !ring.isEmpty else { return false }
        guard let current = currentView, let i = ring.firstIndex(of: current) else {
            // Nothing is showing: this is an open, not a step, and it grows on the open
            // spring with its content crossing over — not sliding in from the side.
            select(forward ? ring[0] : ring[ring.count - 1], direction: 0)
            return true
        }
        var next = i + (forward ? 1 : -1)
        if next < 0 || next >= ring.count {
            guard wrap else { return false }
            next = (next + ring.count) % ring.count
        }
        select(ring[next], direction: forward ? 1 : -1)
        return true
    }

    /// Sections the user types into. While one of them is pinned open, and only then, the
    /// island's window may take key status from the app in front.
    ///
    /// Only Notes, whose whole body is an editor. The clipboard used to be here for the sake
    /// of a search field that was always up; its field is opened by typing now, and a find
    /// asks for the keyboard on its own — so on that section the arrows, the digits and Space
    /// are the island's again until somebody starts a find.
    static let typedSections: Set<HomeSection> = [.notes]

    /// Whether the panel is showing something that is typed into. Derived, never toggled by
    /// a view appearing or disappearing: stepping straight from one such section to another
    /// must not read as "nobody wants the keyboard" for the moment their lifetimes overlap.
    var wantsKeyboard: Bool {
        guard isOpen, case .home(let tab)? = currentView,
              let section = HomeSection(rawValue: tab) else { return false }
        // A find is typing too: the field it opens needs the keyboard for as long as it is up,
        // and every key the island had claimed goes back to the person doing the typing.
        return Self.typedSections.contains(section) || findQuery != nil
    }

    /// The view the panel is on, pinned or peeking; nil when no panel is showing.
    var currentView: IslandView? {
        if let openView { return validated(openView) }
        if hoverPanel != nil, Preferences.shared.hoverToExpand, hoverPeeks { return validated(peekView ?? defaultPeek()) }
        return nil
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

    /// The global shortcut: close whatever is open, else open the panel on what the island
    /// is showing (Home when nothing is live).
    func toggle() {
        if isOpen || presentation.isExpanded {
            collapse(reason: "shortcut")
        } else {
            open(defaultPeek())
        }
    }

    /// The order the switcher lists live activities in: by kind, then by start. Never by
    /// recency, so a slot never moves under the pointer.
    static let ringKindOrder: [ActivityKind] = [.call, .timer, .stopwatch, .download, .calendar, .battery, .bluetooth,
                                                .custom, .focus, .hud, .silent, .unlock, .shelf, .nowPlaying]

    /// Every view the panel can show, in switcher order: the live activities' cards (left of
    /// the cutout), then the Home sections (right of it). Now Playing and the shelf are Home
    /// sections, so they never appear twice.
    var ring: [IslandView] {
        let cards = activities
            .filter { $0.content.hasExpandedView && $0.kind != .nowPlaying && $0.kind != .shelf }
            .sorted { a, b in
                let ra = Self.ringKindOrder.firstIndex(of: a.kind) ?? 99
                let rb = Self.ringKindOrder.firstIndex(of: b.kind) ?? 99
                if ra != rb { return ra < rb }
                return a.startedAt < b.startedAt
            }
            .map { IslandView.activity(id: $0.id) }
        let sections = HomeSection.available(Preferences.shared).map { IslandView.home(tab: $0.rawValue) }
        return cards + sections
    }

    /// The ring as the keyboard walks it.
    var keyboardRing: [IslandView] { ring }

    /// Shortcut modifiers + Tab (forward) or Shift + Tab (backward). Closed: opens the first
    /// (or last) view. Open: moves one step, wrapping around.
    func cycleView(forward: Bool) {
        step(forward: forward, wrap: true)
    }

    /// Closes whatever is open. `reason` goes to the log, so a panel that closed behind the
    /// user's back can be explained from a report.
    func collapse(reason: String = "request") {
        homeWork?.cancel()
        navigationDirection = 0
        if let current = openView { IslandLog.island.notice("closing \(String(describing: current), privacy: .public): \(reason, privacy: .public)") }
        let held = heldAlertIDs
        heldAlertIDs.removeAll()
        let hovering = isHovering
        closedUnderPointer()
        withAnimation(IslandMotion.close) {
            openView = nil
            openPanel = nil
            peekView = nil
            forcedExpandedID = nil
            for id in held { end(id: id) }
            if !hovering, alert != nil {
                alertWork?.cancel()
                alert = nil
            }
        }
        // Anything a louder alert pushed aside gets its turn now.
        if alert == nil { showNextPendingAlert() }
    }

    /// The panel is closing under a pointer resting on it. The pointer is forgotten, and that
    /// island shows no peek until the pointer has left and come back: otherwise the peek
    /// branch drew the same panel straight back, and a Stop, an Escape, picking a clipboard
    /// row or the switcher's close button closed nothing anyone could see.
    private func closedUnderPointer() {
        guard let panel = hoverPanel else { return }
        let leaving = pendingHover.map { !$0.hovering && $0.panel == panel } ?? false
        hoverWork?.cancel()
        pendingHover = nil
        hoverPanel = nil
        // The pointer has already left and only its grace was running, or it ran off the
        // end of a slider: that is an exit, applied now, and not a pointer to keep waiting
        // out — which left the island showing no peek until the next visit.
        if leaving || deferredHoverExit == panel {
            deferredHoverExit = nil
            return
        }
        peekSuppressed = panel
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
            self.openPanel = nil
        }
        homeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// When the user last clicked or keyed the island; a timed close never cuts that short,
    /// and neither does anything that arrives in the tail of the very click that opened it.
    private(set) var lastInteraction = Date.distantPast

    /// Whether a screen point lies on an island; set by the app delegate from its panels.
    var islandHitTest: ((NSPoint) -> Bool)?

    /// The Home section the panel last showed; where Home opens next time.
    static var currentHomeTab: String {
        let stored = UserDefaults.standard.string(forKey: GestureRouter.homeTabKey) ?? HomeSection.fallback.rawValue
        return HomeSection.resolve(stored, prefs: Preferences.shared).rawValue
    }

    private static func selectHomeTab(_ tab: String) {
        guard UserDefaults.standard.string(forKey: GestureRouter.homeTabKey) != tab else { return }
        UserDefaults.standard.set(tab, forKey: GestureRouter.homeTabKey)
    }

    /// Arms the click-outside monitor and the Escape shortcut while something is open, and
    /// disarms both the moment it closes, so neither costs anything at rest.
    private func openStateChanged() {
        lastInteraction = Date()
        if openView != nil { openedAt = Date() }
        keyboardControlChanged()
        if openView != nil {
            watchForAnotherApp()
            watchOurOwnWindows()
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                let type = event.type.rawValue
                let window = event.windowNumber
                DispatchQueue.main.async { self?.clickedElsewhere(type: type, window: window) }
            }
        } else {
            if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
            outsideClickMonitor = nil
            keyWindowObservers.forEach { NotificationCenter.default.removeObserver($0) }
            keyWindowObservers.removeAll()
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
        }
    }

    /// Closes the panel when the user goes somewhere else.
    ///
    /// A click outside was the only way out, and Command-Tab does not make one: the panel
    /// stayed open over Mail with the whole alphabet still claimed as global hot keys, so
    /// every letter typed into a reply was swallowed and opened a find in the island instead.
    /// Leaving for another app is leaving.
    private func watchForAnotherApp() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard Self.isSomebodyElse(app?.bundleIdentifier, ours: Bundle.main.bundleIdentifier) else { return }
            // Command-Tab to an app on another Space changes the Space too, and is leaving
            // all the same: the Command key is still down when the activation arrives.
            let commanded = NSEvent.modifierFlags.contains(.command)
            // Not straight away. A swipe to another Space activates whatever is in front
            // there, and the activation arrives before the Space says it changed; the panel
            // is meant to stay open across a swipe (`AppDelegate.spaceChanged`), and it
            // closed on every swipe that landed on a different app and stayed on one that
            // landed on the same — which looked like chance. So the check waits for the
            // Space's own notification to have had its say.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationSettle) { [weak self] in
                guard let self, commanded || Self.leftForAnotherApp(now: Date(), lastSpaceChange: self.lastSpaceChange) else { return }
                self.collapse(reason: "another app came forward")
            }
        }
    }

    /// How long an activation waits for a Space change that may have caused it.
    static let activationSettle: TimeInterval = 0.3
    /// How recent a Space change has to be to account for an activation.
    static let spaceChangeGrace: TimeInterval = 0.8
    /// When the active Space last changed, see `noteSpaceChanged`.
    private var lastSpaceChange = Date.distantPast

    /// The active Space changed. Told by the app delegate, which hears it.
    func noteSpaceChanged() { lastSpaceChange = Date() }

    /// Whether an app coming forward is the user leaving for it, rather than the Space
    /// under the island having changed and brought it forward.
    static func leftForAnotherApp(now: Date, lastSpaceChange: Date) -> Bool {
        now.timeIntervalSince(lastSpaceChange) > spaceChangeGrace
    }

    /// Whether an app coming forward is one the island should get out of the way of.
    ///
    /// Its own app is not: taking the keyboard for the notes field activates it, and treating
    /// that as leaving would close the panel the moment it was typed into. Nor is an app that
    /// will not say who it is — an agent with no bundle identifier can come forward for a
    /// moment without anybody meaning to leave, and closing on that would be a panel that
    /// shuts by itself.
    static func isSomebodyElse(_ bundleID: String?, ours: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleID != ours
    }
}

extension ActivityCenter {
    /// A mouse-down the system delivered to another application while something is open.
    /// Global monitors are documented not to see our own clicks, but nothing here relies on
    /// that: the click must be past the opening click's tail and land off the island.
    fileprivate func clickedElsewhere(type: UInt, window: Int) {
        guard openView != nil else { return }
        let location = NSEvent.mouseLocation
        let sinceOpened = Date().timeIntervalSince(openedAt)
        let onIsland = islandHitTest?(location) ?? false
        IslandLog.island.notice("mouse-down elsewhere: type \(type, privacy: .public) window \(window, privacy: .public) at \(Double(location.x), privacy: .public),\(Double(location.y), privacy: .public) onIsland \(onIsland, privacy: .public) \(sinceOpened, privacy: .public)s after opening")
        // The tail of the click that opened the panel is not a click outside it.
        guard sinceOpened > 0.4, !onIsland else { return }
        collapse(reason: "click outside")
    }
}

/// A view the user can open on the island and step through with the keyboard.
enum IslandView: Hashable {
    case activity(id: String)
    case home(tab: String)
}
