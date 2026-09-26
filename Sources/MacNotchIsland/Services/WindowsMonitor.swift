import AppKit
import ApplicationServices
import Combine
import ScreenCaptureKit

/// One window on the Mac, as the island shows it.
struct IslandWindow: Identifiable, Equatable {
    let id: CGWindowID
    var title: String
    var appName: String
    var pid: pid_t
    /// Where the window is, in the window server's coordinates: origin at the top-left of the
    /// primary display, y growing downward. Accessibility uses the same space, which is what
    /// lets a window be found and moved from what the window list said about it.
    var frame: CGRect
    var icon: NSImage?
    var thumbnail: NSImage?
    /// Why the window is out of sight, for one that is still open but put away: nil for a
    /// window on screen.
    var away: Away? = nil

    /// The two ways a window is put away without being closed. Both leave it out of the
    /// window server's on-screen list, which is how a minimised window used to vanish from the
    /// strip the moment its own tile's minus button was pressed.
    enum Away: Equatable {
        /// In the Dock.
        case minimised
        /// Behind its app, which was hidden.
        case hidden
    }

    /// What to show under a tile: the window's own title where there is one (reading it needs
    /// the Screen Recording permission), the app's name otherwise.
    var label: String { title.isEmpty ? appName : title }
}

/// A window Accessibility reports as put away — minimised, or belonging to a hidden app — as
/// much of it as it takes to find that window again in the window server's list: whose it
/// is, where it goes back to, and what it is called.
struct PutAwayWindow: Equatable {
    var pid: pid_t
    var frame: CGRect
    var title: String
    var away: IslandWindow.Away

    /// Whether this is the window the window server listed. Where it is decides it, the way
    /// `axWindow(for:)` decides it; a title that disagrees rules a same-sized neighbour out.
    func sits(on window: IslandWindow) -> Bool {
        guard pid == window.pid, titlesAgree(with: window) else { return false }
        return abs(frame.minX - window.frame.minX) < 4 && abs(frame.minY - window.frame.minY) < 4
            && abs(frame.width - window.frame.width) < 4 && abs(frame.height - window.frame.height) < 4
    }

    /// Whether this is the window by name alone: the fallback for a window whose frame the two
    /// sides do not agree on, and only where both sides have a name to go on.
    func isNamed(like window: IslandWindow) -> Bool {
        pid == window.pid && !title.isEmpty && title == window.title
    }

    private func titlesAgree(with window: IslandWindow) -> Bool {
        title.isEmpty || window.title.isEmpty || title == window.title
    }
}

/// Where a window goes when it is snapped. The zones are the ones people reach for on a
/// laptop: two halves, the whole screen, and back to a centred window.
enum SnapZone: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, full, center

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .full: return "rectangle.fill"
        case .center: return "rectangle.center.inset.filled"
        }
    }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .full: return "Fill Screen"
        case .center: return "Centre"
        }
    }

    /// The rect this zone means on a screen, in the window server's top-left coordinates.
    func rect(in visible: CGRect) -> CGRect {
        switch self {
        case .leftHalf:
            return CGRect(x: visible.minX, y: visible.minY, width: (visible.width / 2).rounded(), height: visible.height)
        case .rightHalf:
            let width = (visible.width / 2).rounded()
            return CGRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
        case .full:
            return visible
        case .center:
            let size = CGSize(width: (visible.width * 0.62).rounded(), height: (visible.height * 0.78).rounded())
            return CGRect(x: (visible.midX - size.width / 2).rounded(),
                          y: (visible.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        }
    }
}

/// Every window open on this desktop, with a live picture of each, plus the two things you
/// want to do with one from the notch: bring it to the front, or put it somewhere.
///
/// Pictures come from ScreenCaptureKit, which needs the Screen Recording permission. Without
/// it the windows are still listed — from the window list, which needs no permission — as app
/// tiles, and the section says what is missing and where to grant it. Moving a window needs
/// the Accessibility permission, the same one the media keys already ask for.
///
/// Windows that are put away — minimised into the Dock, or behind an app that was hidden —
/// are out of the window server's sight, and only Accessibility can say which of the windows
/// it lists as off screen are those rather than windows on another desktop or ones an app
/// keeps ordered out. With it they are listed after the ones on screen and drawn dimmed, so
/// the minus button on a tile no longer loses the window it was pressed on. Windows on other
/// desktops stay out: Accessibility does not see them, and the section says "on this desktop".
///
/// Nothing runs unless the section is on screen: the list is refreshed and the pictures
/// retaken on a timer that only exists while somebody is looking.
///
/// Nothing asks another app anything from the main thread. Accessibility waits on the app
/// being asked, and an app that has stopped responding is asked for six seconds by default:
/// clicking a hung app's tile — or its minus, or a zone — froze the whole island for that long.
/// Every question now goes to `axQueue` with half a second to be answered, and only the list
/// that comes back afterwards is published here.
final class WindowsMonitor: ObservableObject {
    static let shared = WindowsMonitor()

    @Published private(set) var windows: [IslandWindow] = []
    /// False when Screen Recording has not been granted: no titles, no pictures.
    @Published private(set) var canCapture = CGPreflightScreenCaptureAccess()
    /// False when Accessibility has not been granted: windows can be raised but not moved.
    @Published private(set) var canMove = AXIsProcessTrusted()

    private var viewers = 0
    private var timer: Timer?
    private var capturing = false
    private var thumbnails: [CGWindowID: NSImage] = [:]
    /// Where each window was when its picture was last asked for. A window that has not moved
    /// keeps the picture it has; see `recaptures`.
    private var pictureFrames: [CGWindowID: CGRect] = [:]
    /// Where the windows are raised, moved, put away and closed: serial, so two clicks act in
    /// the order they were made, and never the main thread.
    private let axQueue = DispatchQueue(label: "com.macnotchisland.windows.ax", qos: .userInitiated)
    private var energyCancellable: AnyCancellable?
    private var icons: [pid_t: NSImage] = [:]

    /// How often the list and the pictures are refreshed while the section is open. Slow
    /// enough to cost nothing, fast enough that a window you just moved looks right.
    static let refreshInterval: TimeInterval = 2.0
    /// The most windows shown. Beyond this the strip is a haystack, and every extra picture
    /// is a capture.
    static let maxWindows = 12
    /// How many of them get a live picture. The rest are app tiles until they come forward,
    /// which keeps a busy Mac from paying for a dozen captures a beat.
    static let maxCaptures = 8
    /// Pixel width every thumbnail is captured at; the tile draws it at half that.
    static let thumbnailWidth: CGFloat = 320
    /// How long another app is given to answer one Accessibility question, here and in the menu
    /// bar's measurement (`MenuBarClearance`). Long enough for a busy app; short enough that one
    /// that has hung costs a beat, not the island. Set on each element asked, see `bounded`.
    static let accessibilityTimeout: Float = 0.5

    /// An element with `accessibilityTimeout` to answer in, handed back.
    ///
    /// Per element, because that is how the setting works: an element read out of another — an
    /// app's windows, a window's close button — starts with the process's default, not with the
    /// timeout of the element it came from, and the default is six seconds. The default itself
    /// is left alone. Set on the system-wide element it becomes every element's, and it cut
    /// short the island's other readers that chose a longer wait for a slower process
    /// (`NotificationWatcher`, `FullscreenMonitor`) along with the ones it was meant for.
    @discardableResult
    static func bounded(_ element: AXUIElement) -> AXUIElement {
        _ = AXUIElementSetMessagingTimeout(element, accessibilityTimeout)
        return element
    }

    /// Windows smaller than this are palettes, HUDs and tool strips, not windows to switch to.
    static let minimumSize = CGSize(width: 120, height: 80)

    /// Owners whose "windows" are parts of the system UI rather than anything to switch to.
    static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Centre", "Control Center",
        "Notification Centre", "Notification Center", "Spotlight", "WindowManager", "Wallpaper",
    ]

    private init() {}

    // MARK: - Lifetime

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        // Pictures kept from the last time the section was open are of then. Every window is
        // pictured afresh on the first beat, whether it has moved since or not.
        pictureFrames.removeAll()
        refresh()
        scheduleTimer()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        energyCancellable = nil
    }

    /// The refresh beat, slowed on battery like every other poller in the app.
    private func scheduleTimer() {
        guard viewers > 0 else { return }
        let interval = Self.refreshInterval * max(1, EnergyPolicy.shared.pollingMultiplier)
        guard timer == nil || abs(interval - (timer?.timeInterval ?? 0)) > 0.01 else { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Reading

    /// Re-reads the two permissions and nothing else: cheap enough for a settings pane to
    /// poll while it is open, with no window list and no captures.
    func refreshPermissions() {
        let allowed = CGPreflightScreenCaptureAccess()
        if canCapture != allowed { canCapture = allowed }
        let trusted = AXIsProcessTrusted()
        if canMove != trusted { canMove = trusted }
    }

    func refresh() {
        refreshPermissions()
        let allowed = canCapture
        let trusted = canMove
        // The window server's list is walked off the main thread, and so is Accessibility,
        // which answers at the speed of the slowest app it is asked about; what they say is
        // turned into tiles (and their app icons, which is AppKit's business) back on it.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = Self.windowServerList()
            let away = trusted ? Self.putAwayWindows(of: Self.appsWithWindowsOutOfSight(in: info)) : []
            DispatchQueue.main.async { self?.apply(Self.list(now: info, putAway: away), capturing: allowed) }
        }
    }

    private func apply(_ listed: [IslandWindow], capturing: Bool) {
        guard viewers > 0 else { return }
        // Keep the picture taken last time until a fresh one arrives, so a tile never blinks.
        let merged = listed.map { window -> IslandWindow in
            var copy = window
            copy.icon = icon(for: window.pid)
            copy.thumbnail = thumbnails[window.id]
            return copy
        }
        if windows != merged { windows = merged }
        let live = Set(listed.map(\.id))
        thumbnails = thumbnails.filter { live.contains($0.key) }
        // An app that has gone takes its icon with it: process ids are reused, and a stale
        // icon would then belong to somebody else.
        let pids = Set(listed.map(\.pid))
        icons = icons.filter { pids.contains($0.key) }
        guard capturing else { return }
        let wanted = Self.recaptures(listed, previousFrames: pictureFrames, pictured: Set(thumbnails.keys))
        // Remembered only once a pass has actually been asked for: a beat that finds the last
        // one still running leaves the old frames, so a window that moved in the meantime is
        // still new to the beat after.
        guard wanted.isEmpty || capture(wanted) else { return }
        var frames: [CGWindowID: CGRect] = [:]
        for window in listed where window.away == nil { frames[window.id] = window.frame }
        pictureFrames = frames
    }

    /// The windows to take a fresh picture of this beat, front to back.
    ///
    /// Only what is on screen can be captured, and only the first `limit` of those are
    /// pictured at all. A window put away keeps the picture it had when it went, which is also
    /// the picture of what comes back when it is clicked. Of the rest, the ones worth a capture
    /// are the front window — the one being worked in, so the one whose contents change — any
    /// window whose frame is not where it was last beat, and any that has no picture yet. Every
    /// one of eight used to be captured every two seconds whether anything about it had
    /// changed or not: eight ScreenCaptureKit round trips a beat to redraw the same pictures.
    ///
    /// Pure, so it can be tested without a window server.
    static func recaptures(_ listed: [IslandWindow], previousFrames: [CGWindowID: CGRect], pictured: Set<CGWindowID>,
                           limit: Int = maxCaptures) -> [CGWindowID] {
        let onScreen = listed.filter { $0.away == nil }.prefix(max(0, limit))
        var wanted: [CGWindowID] = []
        for (index, window) in onScreen.enumerated()
            where index == 0 || !pictured.contains(window.id) || previousFrames[window.id] != window.frame {
            wanted.append(window.id)
        }
        return wanted
    }

    /// An app's icon, looked up once and kept while that app still has a window: asking again
    /// on every pass would hand back a different image each time and make the list look
    /// changed when nothing had.
    private func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        icons[pid] = icon
        return icon
    }

    /// The window server's whole list, on screen and off. What is off screen is kept only
    /// where Accessibility vouches for it, see `list(now:putAway:)`.
    static func windowServerList() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// Windows worth showing: the ones on screen, front to back as the window server lists
    /// them, then the ones put away. An off-screen window is only listed when one of `putAway`
    /// is that window; the rest of the off-screen list is other desktops and windows apps keep
    /// ordered out, none of which a click on a tile could bring back.
    ///
    /// Pure, so the list can be tested without a window server.
    static func list(now: [[String: Any]]? = nil, putAway: [PutAwayWindow] = []) -> [IslandWindow] {
        let info = now ?? windowServerList()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var shown: [IslandWindow] = []
        var outOfSight: [IslandWindow] = []
        for entry in info {
            guard let found = candidate(entry, ownPID: ownPID) else { continue }
            if found.onScreen {
                shown.append(found.window)
                if shown.count >= maxWindows { break }
            } else {
                outOfSight.append(found.window)
            }
        }
        return Array((shown + claimed(outOfSight, by: putAway)).prefix(maxWindows))
    }

    /// The windows out of sight that are ones Accessibility reported put away, in the window
    /// server's order, each marked with how it was put away.
    ///
    /// Each put-away window answers for one listed window at most, so two entries of the same
    /// size cannot both be taken for it. And where it sits is asked of the whole list before
    /// its name is asked of any of it. Asked entry by entry — where it sits, else what it is
    /// called — a window earlier in the list took by name alone the one a later entry sat
    /// exactly on: two Safari windows called "Start Page", one on another desktop and one in
    /// the Dock, and the tile carried the other desktop's window — its id, so a picture that
    /// never came, and its frame, so Snap moved the wrong one — and was counted "on this
    /// desktop". The name is only the fallback for what nothing sits on.
    ///
    /// Pure, like `list`.
    static func claimed(_ outOfSight: [IslandWindow], by putAway: [PutAwayWindow]) -> [IslandWindow] {
        var unclaimed = putAway
        var reasons = [IslandWindow.Away?](repeating: nil, count: outOfSight.count)
        let passes: [(PutAwayWindow, IslandWindow) -> Bool] = [
            { $0.sits(on: $1) },
            { $0.isNamed(like: $1) },
        ]
        for matches in passes {
            for (index, window) in outOfSight.enumerated() where reasons[index] == nil {
                guard let taken = unclaimed.firstIndex(where: { matches($0, window) }) else { continue }
                reasons[index] = unclaimed.remove(at: taken).away
            }
        }
        return outOfSight.indices.compactMap { index in
            guard let reason = reasons[index] else { return nil }
            var window = outOfSight[index]
            window.away = reason
            return window
        }
    }

    /// One entry of the window server's list as a tile, if it is a window worth switching to,
    /// and whether it is on screen. A list taken with `.optionAll` marks the ones on screen
    /// and leaves the key out of the rest.
    private static func candidate(_ window: [String: Any], ownPID: pid_t) -> (window: IslandWindow, onScreen: Bool)? {
        guard let id = window[kCGWindowNumber as String] as? CGWindowID,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
              let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDict),
              frame.width >= minimumSize.width, frame.height >= minimumSize.height else { return nil }
        let alpha = (window[kCGWindowAlpha as String] as? Double) ?? 1
        guard alpha > 0.1 else { return nil }
        let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
        guard !owner.isEmpty, !ignoredOwners.contains(owner) else { return nil }
        let title = (window[kCGWindowName as String] as? String) ?? ""
        let onScreen = (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
        // The icon is filled in by `apply`, from a cache: asking AppKit for it here would
        // hand back a different NSImage every pass and make every list look changed.
        return (IslandWindow(id: id, title: title, appName: owner, pid: pid, frame: frame,
                             icon: nil, thumbnail: nil), onScreen)
    }

    /// The apps with a window the window server lists as off screen, which are the only ones
    /// worth asking Accessibility about: an app with every window in view has nothing put away.
    static func appsWithWindowsOutOfSight(in info: [[String: Any]]) -> Set<pid_t> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return Set(info.compactMap { entry -> pid_t? in
            guard let found = candidate(entry, ownPID: ownPID), !found.onScreen else { return nil }
            return found.window.pid
        })
    }

    /// What Accessibility says each of those apps has put away: its minimised windows, and
    /// every window of one that is hidden. Only ordinary apps, the ones with a Dock icon —
    /// anything else has no Dock to minimise into and nothing to hide.
    ///
    /// Off the main thread. `NSRunningApplication` is thread safe, and each app is given half
    /// a second to answer rather than the default six, so one that has stopped responding
    /// costs the strip a beat instead of holding every refresh behind it — the app, and each
    /// window read out of it, since neither inherits the other's (`bounded`).
    private static func putAwayWindows(of pids: Set<pid_t>) -> [PutAwayWindow] {
        guard !pids.isEmpty, AXIsProcessTrusted() else { return [] }
        var result: [PutAwayWindow] = []
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            let hidden = app.isHidden
            let element = bounded(AXUIElementCreateApplication(pid))
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows.map(bounded) {
                // Minimised wins over hidden: showing the app again leaves a minimised window
                // in the Dock, so that is where it is.
                let minimised = isMinimised(window)
                guard minimised || hidden, let frame = frame(of: window) else { continue }
                result.append(PutAwayWindow(pid: pid, frame: frame, title: title(of: window) ?? "",
                                            away: minimised ? .minimised : .hidden))
            }
        }
        return result
    }

    private static func isMinimised(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    // MARK: - Pictures

    /// Starts a pass of pictures, and says whether it did: one is already running, or there is
    /// nothing to take.
    @discardableResult
    private func capture(_ ids: [CGWindowID]) -> Bool {
        guard !capturing, !ids.isEmpty else { return false }
        capturing = true
        Task { [weak self] in
            let shots = await Self.shots(of: ids)
            // Resolved out here, into a constant. Unwrapping inside `MainActor.run` reads a
            // captured *variable* across an actor hop, which Swift 6 refuses outright.
            guard let monitor = self else { return }
            await MainActor.run {
                monitor.capturing = false
                guard !shots.isEmpty else { return }
                for (id, image) in shots { monitor.thumbnails[id] = image }
                monitor.windows = monitor.windows.map { window in
                    guard let image = shots[window.id] else { return window }
                    var copy = window
                    copy.thumbnail = image
                    return copy
                }
            }
        }
        return true
    }

    /// One picture per window, captured off the main thread. A window that cannot be captured
    /// (it went away mid-pass, or it belongs to a Space that is not on screen) is simply left
    /// out; the tile keeps the picture it had.
    private static func shots(of ids: [CGWindowID]) async -> [CGWindowID: NSImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [:] }
        var byID: [CGWindowID: SCWindow] = [:]
        for window in content.windows { byID[window.windowID] = window }
        var result: [CGWindowID: NSImage] = [:]
        for id in ids {
            guard let window = byID[id], window.frame.width > 1, window.frame.height > 1 else { continue }
            let configuration = SCStreamConfiguration()
            let scale = min(1, thumbnailWidth / window.frame.width)
            configuration.width = max(1, Int((window.frame.width * scale).rounded()))
            configuration.height = max(1, Int((window.frame.height * scale).rounded()))
            configuration.showsCursor = false
            configuration.scalesToFit = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { continue }
            result[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        return result
    }

    // MARK: - Permissions

    /// Asks for Screen Recording. macOS only shows its dialog once per app, so the button in
    /// the section opens System Settings as well.
    func requestCapture() {
        if !CGRequestScreenCaptureAccess() {
            SystemSettingsPane.screenRecording.open()
        }
        refresh()
    }

    /// Asks for Accessibility, with the system's own prompt.
    func requestMove() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(options as CFDictionary) {
            SystemSettingsPane.accessibility.open()
        }
        refresh()
    }

    // MARK: - Acting on a window

    /// Brings a window to the front and gives it the keyboard — out of the Dock, or from
    /// behind its hidden app, where it was put away. The panel closes with it: the point of
    /// the click was to get to that window, not to keep looking at the notch.
    func focus(_ window: IslandWindow) {
        ActivityCenter.shared.collapse(reason: "switched to a window")
        let app = NSRunningApplication(processIdentifier: window.pid)
        // Shown before anything is raised: a window of a hidden app stays out of sight however
        // far forward it is brought.
        if app?.isHidden == true { app?.unhide() }
        // Without Accessibility this is all there is: the app comes forward with whichever
        // window it had in front, which is right far more often than not.
        guard AXIsProcessTrusted() else {
            app?.activate()
            return
        }
        act(on: window, lenient: true, { element in
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }, then: { _ in
            // After the raise, as before: the app comes forward with that window in front.
            app?.activate()
        })
    }

    /// Hides the app a window belongs to, or shows it again. Its windows stay in the strip
    /// either way — dimmed while the app is hidden — and the list is taken again a beat later,
    /// by which time the window server has caught up, so the tiles change with the app rather
    /// than a refresh after it.
    func setHidden(_ hidden: Bool, appOf window: IslandWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if hidden { app.hide() } else { app.unhide() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    /// Lays several windows out side by side on one screen, the way macOS's own tiling does
    /// but for the windows *you* picked rather than the two that happen to be in front.
    ///
    /// They all go on the screen the first of them is on: tiling is a thing you do to one
    /// screen. Windows the Accessibility permission cannot reach are skipped rather than
    /// abandoning the ones it can. The moving happens on `axQueue`; what comes back is whether
    /// it was sent there at all.
    @discardableResult
    func tile(_ windows: [IslandWindow]) -> Bool {
        guard windows.count > 1 else { return false }
        guard AXIsProcessTrusted() else {
            requestMove()
            return false
        }
        let visible = Self.visibleFrame(containing: windows[0].frame)
        let placed = Array(zip(windows, Self.tileFrames(count: windows.count, in: visible)))
        // A window behind its hidden app is laid out where nobody can see it until the app is
        // shown.
        for (window, _) in placed where window.away == .hidden {
            NSRunningApplication(processIdentifier: window.pid)?.unhide()
        }
        axQueue.async { [weak self] in
            for (window, target) in placed {
                guard let element = Self.axWindow(for: window) else { continue }
                // One in the Dock comes out of it.
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                Self.setFrame(element, to: target)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
            // The list is now wrong by every window that moved. Ask again straight away and
            // once more a beat later, by which time the window server has the new frames.
            DispatchQueue.main.async { self?.refresh(andAgainAfter: 0.35) }
        }
        return true
    }

    /// Where each of `count` windows goes on one screen: two side by side, three across a wide
    /// screen, four in quarters, and beyond that a grid as square as it can be, with a short
    /// last row sharing the width between the windows that are in it rather than leaving a
    /// hole. Edges are rounded from the screen rather than each rectangle being rounded on its
    /// own, so neighbours meet exactly and the row adds up to the screen.
    ///
    /// Pure, so the arithmetic can be tested without a window to move.
    static func tileFrames(count: Int, in visible: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [visible] }
        // Three across, not two-and-one: on a laptop's width three columns is the layout
        // people mean, and a grid would leave one of them twice the size of the others.
        let columns = count == 3 ? 3 : Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        var frames: [CGRect] = []
        for row in 0..<rows {
            let inRow = min(columns, count - row * columns)
            guard inRow > 0 else { break }
            let top = edge(visible.minY, visible.height, row, rows)
            let bottom = edge(visible.minY, visible.height, row + 1, rows)
            for column in 0..<inRow {
                let left = edge(visible.minX, visible.width, column, inRow)
                let right = edge(visible.minX, visible.width, column + 1, inRow)
                frames.append(CGRect(x: left, y: top, width: right - left, height: bottom - top))
            }
        }
        return frames
    }

    private static func edge(_ origin: CGFloat, _ length: CGFloat, _ index: Int, _ of: Int) -> CGFloat {
        (origin + length * CGFloat(index) / CGFloat(of)).rounded()
    }

    /// Puts a window in a zone of the screen it is on, and brings it forward so the result is
    /// visible. Does nothing without the Accessibility permission, and asks for it. Returns
    /// whether the move was sent; it is made on `axQueue`.
    @discardableResult
    func snap(_ window: IslandWindow, to zone: SnapZone) -> Bool {
        guard AXIsProcessTrusted() else {
            requestMove()
            return false
        }
        let target = zone.rect(in: Self.visibleFrame(containing: window.frame))
        act(on: window, { element in
            // A window put away comes back to be put somewhere: out of the Dock first, as
            // `tile` does, and its app is shown by the `activate` that follows.
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            Self.setFrame(element, to: target)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }, then: { [weak self] found in
            // Not found: the window moved since the list was taken and cannot be told from its
            // siblings. A fresh list rather than moving the wrong window.
            guard found else {
                self?.refresh()
                return
            }
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            // The list is now wrong by exactly the window that moved. Ask again straight away
            // and once more a beat later, by which time the window server has the new frame
            // and the tile can be redrawn where the window actually went.
            self?.refresh(andAgainAfter: 0.35)
        })
        return true
    }

    /// Opens files with the app a window belongs to. Dropping a file on a tile is "open this
    /// in that", which needs no Accessibility: it is the same thing as dropping it on the
    /// app's Dock icon.
    @discardableResult
    func open(_ urls: [URL], with window: IslandWindow) -> Bool {
        guard !urls.isEmpty,
              let app = NSRunningApplication(processIdentifier: window.pid)?.bundleURL else { return false }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        ActivityCenter.shared.collapse(reason: "opened a file in a window's app")
        return true
    }

    /// Sends a window to the next display, keeping the share of the screen it had. The one
    /// move the zones could not make: they all rearrange a window on the display it is
    /// already on.
    @discardableResult
    func sendToNextDisplay(_ window: IslandWindow) -> Bool {
        let screens = Self.displays()
        guard screens.count > 1, let here = Self.displayIndex(of: window.frame, in: screens) else { return false }
        guard AXIsProcessTrusted() else {
            requestMove()
            return false
        }
        let target = Self.mapped(window.frame, from: screens[here].visible, to: screens[(here + 1) % screens.count].visible)
        act(on: window, { element in
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            Self.setFrame(element, to: target)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }, then: { [weak self] found in
            guard found else {
                self?.refresh()
                return
            }
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            self?.refresh(andAgainAfter: 0.35)
        })
        return true
    }

    /// Puts a window in the Dock. The one thing the zones could not do: every other button on
    /// a tile moves a window somewhere on this screen, and sometimes where you want it is off
    /// the screen entirely. Its tile stays, dimmed, and a click on it brings the window back.
    @discardableResult
    func minimise(_ window: IslandWindow) -> Bool {
        guard AXIsProcessTrusted() else {
            requestMove()
            return false
        }
        act(on: window, { element in
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }, then: { [weak self] found in
            // Once now, and once when the Dock's animation is over and the window server has
            // the window out of view, which is when the tile can be drawn as put away.
            guard found else {
                self?.refresh()
                return
            }
            self?.refresh(andAgainAfter: 0.7)
        })
        return true
    }

    /// Closes a window, as its own close button would.
    @discardableResult
    func close(_ window: IslandWindow) -> Bool {
        guard AXIsProcessTrusted() else {
            requestMove()
            return false
        }
        act(on: window, { element in
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
                  let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
            AXUIElementPerformAction(Self.bounded(button as! AXUIElement), kAXPressAction as CFString)   // type checked just above
        }, then: { [weak self] _ in self?.refresh() })
        return true
    }

    /// Finds the window's Accessibility element and does `work` to it, on `axQueue`; then
    /// `done` on the main thread, told whether the window was found.
    private func act(on window: IslandWindow, lenient: Bool = false,
                     _ work: @escaping (AXUIElement) -> Void, then done: @escaping (Bool) -> Void) {
        axQueue.async {
            let element = Self.axWindow(for: window, lenient: lenient)
            if let element { work(element) }
            let found = element != nil
            DispatchQueue.main.async { done(found) }
        }
    }

    /// The list now, and once more `delay` later, when the window server has caught up with
    /// whatever was just done to a window.
    private func refresh(andAgainAfter delay: TimeInterval) {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }

    // MARK: - Accessibility plumbing

    /// The Accessibility element for a window the window list told us about. There is no
    /// public way to ask for a window by its number, so the app's windows are matched on what
    /// both sides agree about: where the window is, then what it is called.
    ///
    /// A window that cannot be identified is never guessed at. The list can be a couple of
    /// seconds old, and an app usually has several windows: taking "the first one" would move
    /// — or close — a window the user did not point at. `lenient` is for raising a window,
    /// where the worst case is the app's own frontmost window coming forward instead.
    ///
    /// Off the main thread, on `axQueue`, and with half a second for the app to answer rather
    /// than the default six — both the app and every window handed back, which is the element
    /// the caller goes on to raise, move or close (`bounded`).
    static func axWindow(for window: IslandWindow, lenient: Bool = false) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = bounded(AXUIElementCreateApplication(window.pid))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let listed = value as? [AXUIElement], !listed.isEmpty else { return nil }
        let elements = listed.map(bounded)
        if let byFrame = elements.first(where: { element in
            guard let frame = frame(of: element) else { return false }
            return abs(frame.minX - window.frame.minX) < 4 && abs(frame.minY - window.frame.minY) < 4
                && abs(frame.width - window.frame.width) < 4 && abs(frame.height - window.frame.height) < 4
        }) { return byFrame }
        if !window.title.isEmpty, let byTitle = elements.first(where: { title(of: $0) == window.title }) {
            return byTitle
        }
        // One window and one candidate can only mean each other.
        if elements.count == 1 { return elements[0] }
        return lenient ? elements.first : nil
    }

    static func setFrame(_ element: AXUIElement, to rect: CGRect) {
        var position = rect.origin
        var size = rect.size
        // Size first, then position, then size again: a window with a minimum size clamps the
        // size it is given, and one near the screen edge clamps the position, so each pass
        // corrects what the other could not do on its own.
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),   // type checked just above
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Screens

    /// The usable part of the screen a window is on (menu bar and Dock excluded), in the
    /// window server's top-left coordinates.
    static func visibleFrame(containing frame: CGRect) -> CGRect {
        let screens = displays()
        guard let index = Self.displayIndex(of: frame, in: screens) else { return frame }
        return screens[index].visible
    }

    /// Every display, in the order macOS lists them, with both rectangles flipped into the
    /// window server's top-left coordinates — the ones the window list reports and `setFrame`
    /// writes. One function, because getting the flip wrong moves a window to the wrong place
    /// on the right display and is very hard to see in a diff.
    static func displays() -> [(full: CGRect, visible: CGRect)] {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        return screens.map { screen in
            (full: CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                          width: screen.frame.width, height: screen.frame.height),
             visible: CGRect(x: screen.visibleFrame.minX, y: primaryHeight - screen.visibleFrame.maxY,
                             width: screen.visibleFrame.width, height: screen.visibleFrame.height))
        }
    }

    /// Which display a window is on: the one its centre is in, or failing that the one it
    /// overlaps most. A window dragged half off the edge still belongs somewhere.
    static func displayIndex(of frame: CGRect, in screens: [(full: CGRect, visible: CGRect)]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let index = screens.firstIndex(where: { $0.full.contains(centre) }) { return index }
        return screens.indices.max {
            screens[$0].full.intersection(frame).area < screens[$1].full.intersection(frame).area
        }
    }

    /// Where a window lands on another display: the same fractions of the usable area it
    /// filled on the one it came from, so a half stays a half, a small window stays small,
    /// and nothing arrives hanging off an edge.
    static func mapped(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
        guard from.width > 0, from.height > 0, to.width > 0, to.height > 0 else { return to }
        let width = min(1, frame.width / from.width) * to.width
        let height = min(1, frame.height / from.height) * to.height
        let x = to.minX + (frame.minX - from.minX) / from.width * to.width
        let y = to.minY + (frame.minY - from.minY) / from.height * to.height
        return CGRect(x: min(max(x, to.minX), to.maxX - width).rounded(),
                      y: min(max(y, to.minY), to.maxY - height).rounded(),
                      width: width.rounded(), height: height.rounded())
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
