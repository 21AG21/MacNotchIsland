import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// What is left to do about a copy of the app that has been asked to quit.
enum CopyRetirement: Equatable {
    /// It has gone, and whatever it wrote on the way out is on disk.
    case done
    /// It is still there and its time is up.
    case force
    /// It is still there and there is still time.
    case waitAgain

    /// Whether the copy that has just launched may go ahead yet.
    ///
    /// Waiting is what keeps the two copies from writing over each other's history, but
    /// waiting on a copy that is never going to quit would hold a launch open for as long as
    /// that copy sulks — so the wait is bounded by the same deadline that decides when it is
    /// killed instead. A copy that had to be killed never saved anything on its way out, so
    /// once it has been killed there is nothing left of it to wait for.
    static func next(stillRunning: Int, secondsLeft: TimeInterval) -> CopyRetirement {
        guard stillRunning > 0 else { return .done }
        return secondsLeft > 0 ? .waitAgain : .force
    }
}

/// How many times the island has been built, when it last was, and what for.
///
/// "The notch disappeared after my Mac slept" is the complaint every app in this category
/// has open, and the answer to it is a rebuild — which then has to be accounted for, or the
/// next question is whether it came back on its own or was reloaded by hand, and nobody can
/// say. Every path that builds the panels writes here, so a diagnostics report can.
struct PanelHealth: Equatable {
    var lastRebuiltAt: Date?
    var rebuildCount = 0
    var lastRebuildReason = ""
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panels: [NotchPanel] = []
    private var statusItem: StatusItemController?
    private var hub: ServiceHub?
    private var cancellables = Set<AnyCancellable>()
    private var screenRebuildWork: DispatchWorkItem?
    private var wakeCheckWork: DispatchWorkItem?
    /// Whether the menu bar was set to hide itself when the defaults were last looked at, so
    /// that only a change to it goes to the screen-parameters path. See `menuBarSettingChanged`.
    private var menuBarHid = NotchGeometry.menuBarAutoHides
    /// Read-only from outside: only the rebuild paths may say a rebuild happened.
    private(set) var panelHealth = PanelHealth()

    func applicationDidFinishLaunching(_ notification: Notification) {
        RunRecord.begin()
        IslandLog.island.notice("launched pid \(Int(ProcessInfo.processInfo.processIdentifier), privacy: .public) from \(Bundle.main.bundlePath, privacy: .public)")
        catchTermination()
        // No process-wide Accessibility timeout. Set on the system-wide element it is every
        // element's default, and it cut short the readers that chose a longer wait of their own
        // (`NotificationWatcher`, `FullscreenMonitor`). Each reader sets its own, element by
        // element (`WindowsMonitor.bounded`); one it does not set waits the system's six seconds.
        // Asked to quit here, at the very top, so an older copy has the whole of this launch
        // to go in; nothing it left behind is read until it has.
        let retiring = Self.retireOtherCopies()
        NSApp.setActivationPolicy(.accessory)
        rebuildPanels(reason: "launch")
        statusItem = StatusItemController()
        // The history on disk stays the older copy's to write until it has gone. It saves the
        // clipboard on its way out, that file is rewritten whole, and a new copy that had
        // already read it would save it back over the top a moment later with the old copy's
        // last few seconds cut out of it — silently, since both files are perfectly valid.
        // Nearly every launch has no older copy to wait for, and this runs here and now.
        Self.whenRetired(retiring) { [weak self] in
            guard let self else { return }
            // Everything that keeps a whole-file store, together, and only now: the copy being
            // replaced rewrites each of these on its way out, and whoever reads first and
            // writes last wins.
            ClipboardStore.shared.loadIfNeeded()
            NotesStore.shared.loadIfNeeded()
            NotificationInbox.shared.loadIfNeeded()
            // The services, a turn after the island has been placed rather than in the same
            // breath. Starting them is some twenty-five monitors' worth of first readings — the
            // camera list, the audio devices, the Downloads folder, the Now Playing helper, the
            // private frameworks the brightness and the keyboard's light are read through — and
            // all of it used to run inside this method, before launch had even finished and
            // before the island it was launching had been given a turn to draw. Nothing that
            // has to come first is waiting on it: a URL that opened the app is handled with or
            // without the hub, the way it already is while an older copy is being waited out
            // (see `IslandTimer.loadAlarmsIfNeeded`), and the stores above are read before
            // anything here can write them.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hub == nil else { return }
                self.hub = ServiceHub()
                self.hub?.start()
                // The rail's brightness is read on a queue now, and the first reading is asked
                // for when this is made; made here, it has long landed by the time a rail is
                // drawn, and whether there is a slider at all is known from the first frame.
                _ = BrightnessControl.shared
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { WelcomeWindowController.shared.showIfFirstLaunch() }
        for delay in [5.0, 30.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.rebuildPanelsIfGeometryChanged() }
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        // "Automatically hide and show the menu bar" moves the floating pill, and is part of
        // what the panels were built for (`NotchPanel.displayKey`). Switching it changes the
        // display's visible frame, which the path above hears; the defaults changing is heard
        // here too, and goes the same way, settled and compared before anything is rebuilt.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(menuBarSettingChanged),
                                               name: UserDefaults.didChangeNotification,
                                               object: nil)
        // The island belongs to the notch, not to a Space or an app: whenever the desktop
        // underneath changes, put every panel back on top and over its notch.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(spaceChanged),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Sleep is not a quit, so nothing else writes here — but a Mac that never comes back
        // from it should still have the last sentence somebody typed.
        workspace.addObserver(self, selector: #selector(saveEverything),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(saveEverything),
                              name: NSWorkspace.willPowerOffNotification, object: nil)
        // Coming back is where every app of this kind loses its island: the window is still
        // there as far as the app knows, and it is not on the screen. The screen-parameters
        // path above only hears about a display that changed; a display that came back the
        // same size, with the panel ordered out from under it, says nothing to anybody. So
        // each way the Mac can come back is heard as well — the whole machine waking, the
        // displays alone (they sleep on their own, and wake first), and this login session
        // coming back to the front after another user's — and each is followed by a look,
        // not by a rebuild.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(wokeUp(_:)), name: name, object: nil)
        }

        let prefs = Preferences.shared
        Publishers.Merge3(
            prefs.$showOnAllDisplays.dropFirst().map { _ in () },
            prefs.$notchWidthOverride.dropFirst().map { _ in () },
            prefs.$notchHeightOverride.dropFirst().map { _ in () }
        )
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.rebuildPanels(reason: "settings changed") }
        .store(in: &cancellables)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { LiveActivityAPI.shared.handle(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Every deliberate quit is recorded with who asked for it: the menu bar item, another
    /// copy of the app retiring this one, or the system. A run that ends any other way leaves
    /// no such record, which is how the next run knows it vanished.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RunRecord.end(Self.quitRequester())
        Self.saveEverythingNow()
        return .terminateNow
    }

    /// The scratchpad, the clipboard history and the notification history are all written a
    /// moment after they change, and quitting is quicker than that moment. Nothing waits for a
    /// debounce on the way out. Called for a menu-bar quit, a SIGTERM, and a log out or restart.
    private static func saveEverythingNow() {
        NotesStore.shared.flush()
        ClipboardStore.shared.flush()
        // What arrived in the last minute before a quit is exactly what somebody comes back
        // looking for.
        NotificationInbox.shared.flush()
    }

    @objc private func saveEverything() { Self.saveEverythingNow() }

    /// `kill` (and the `pkill` in the install steps) sends SIGTERM, which would otherwise end
    /// the process without a word. It is turned into an ordinary quit, so it is recorded like one.
    private var terminationSignal: DispatchSourceSignal?
    private static var signalledQuit: String?

    private func catchTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Self.signalledQuit = "SIGTERM (kill or pkill)"
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignal = source
    }

    private static func quitRequester() -> String {
        if let signalled = signalledQuit { return signalled }
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return "from inside the app" }
        // keySenderPIDAttr, 'spid': the process that sent the quit event.
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(0x7370_6964))?.int32Value else {
            return "Apple event without a sender"
        }
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName ?? "pid \(pid)"
        let path = app?.bundleURL?.path ?? "?"
        return "quit event from \(name) (pid \(pid), \(path))"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ActivityCenter.shared.showHome()
        return false
    }

    /// How long a copy that has been asked to quit is given before it is made to. It is also
    /// how long the new copy will hold off reading what the old one is still writing.
    private static let retirementDeadline: TimeInterval = 2
    /// Short enough that an ordinary quit — a fraction of a second — is not sat out to the end
    /// of the deadline, and cheap enough that asking forty times costs nothing.
    private static let retirementPollInterval: TimeInterval = 0.05

    /// Runs `proceed` once no older copy is left — at once when there was none to begin with,
    /// which is the ordinary launch and must stay instant. The main thread is never blocked:
    /// a launch that sat still for two seconds would be a worse fault than the one this fixes.
    private static func whenRetired(_ others: [NSRunningApplication], then proceed: @escaping () -> Void) {
        guard !others.isEmpty else { return proceed() }
        waitForRetirement(of: others, until: Date().addingTimeInterval(retirementDeadline), then: proceed)
    }

    private static func waitForRetirement(of others: [NSRunningApplication],
                                          until deadline: Date,
                                          then proceed: @escaping () -> Void) {
        let left = others.filter { !$0.isTerminated }
        switch CopyRetirement.next(stillRunning: left.count, secondsLeft: deadline.timeIntervalSinceNow) {
        case .done:
            proceed()
        case .force:
            for other in left {
                IslandLog.panel.error("the older copy (pid \(Int(other.processIdentifier), privacy: .public)) would not quit; forcing it")
                other.forceTerminate()
            }
            proceed()
        case .waitAgain:
            DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.retirementPollInterval) {
                AppDelegate.waitForRetirement(of: left, until: deadline, then: proceed)
            }
        }
    }

    /// Two copies (one in /Applications and one still running from a Downloads folder, say)
    /// would draw two islands on the same notch and fight over every click. The copy the user
    /// just launched is the one they want, so any older copy is asked to quit. Hands back the
    /// copies it asked, which are the ones `whenRetired` waits on.
    private static func retireOtherCopies() -> [NSRunningApplication] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = NSRunningApplication.current
        // Only copies that started before this one are retired; a copy that started later is
        // about to retire us, and two copies must never retire each other.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { other in
            guard other.processIdentifier != me else { return false }
            if let theirs = other.launchDate, let ours = mine.launchDate, theirs != ours { return theirs < ours }
            return other.processIdentifier < me
        }
        for other in others {
            IslandLog.panel.error("another copy is running (pid \(Int(other.processIdentifier), privacy: .public)); asking it to quit")
            other.terminate()
        }
        return others
    }

    /// The island belongs to the notch, not to a Space: whatever the user had open stays open
    /// across a swipe, and the panel is refitted over the new desktop. Each panel keeps its own
    /// place in the window order (`NotchPanel.assertOnTop`), for this and for every other way
    /// the windows underneath can change.
    @objc private func spaceChanged() {
        IslandLog.panel.notice("space changed")
        ActivityCenter.shared.noteSpaceChanged()
        for panel in panels { panel.refit() }
    }

    /// Any default changing, this app's own included, which is most of them: only the menu
    /// bar's hide setting moving on from what it was goes on to `screensChanged`. Posted on
    /// whichever thread wrote the default, and looked at on the main one.
    @objc private func menuBarSettingChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.menuBarSettingChanged() }
            return
        }
        let hides = NotchGeometry.menuBarAutoHides
        guard hides != menuBarHid else { return }
        menuBarHid = hides
        IslandLog.panel.notice("the menu bar \(hides ? "hides itself" : "stays", privacy: .public) now")
        screensChanged()
    }

    @objc private func screensChanged() {
        // didChangeScreenParameters fires several times per physical event, and also when a
        // full-screen app hides the menu bar. Settle first, then rebuild only if the displays
        // themselves changed; otherwise just make sure the panels are still where they belong.
        screenRebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.rebuildPanelsIfGeometryChanged() else { return }
            for panel in self.panels {
                panel.orderFrontRegardless()
                panel.refit()
            }
        }
        screenRebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// How long after the Mac says it is back before the island is looked at. Long enough for
    /// the displays to be up and for the screen-parameters path to have had its say first, so
    /// that on an ordinary wake this finds everything in order and does nothing — one look,
    /// no rebuild, no flicker. It is the safety net under that path, not a second copy of it.
    static let wakeCheckDelay: TimeInterval = 2

    @objc private func wokeUp(_ note: Notification) {
        let reason = Self.wakeReason(note.name)
        IslandLog.panel.notice("\(reason, privacy: .public); checking the island shortly")
        // The three wakes arrive in a burst: one look covers them all, named for the last.
        wakeCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recoverAfterWake(reason) }
        wakeCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeCheckDelay, execute: work)
    }

    private static func wakeReason(_ name: Notification.Name) -> String {
        switch name {
        case NSWorkspace.didWakeNotification: return "woke from sleep"
        case NSWorkspace.screensDidWakeNotification: return "displays woke"
        case NSWorkspace.sessionDidBecomeActiveNotification: return "session came to the front"
        default: return name.rawValue
        }
    }

    /// A look at the island after a wake, and a rebuild only if the look finds something
    /// wrong. The judgement is `wakeNeedsRebuild`; this only gathers what it is asked about.
    private func recoverAfterWake(_ reason: String) {
        let (built, wanted) = displayKeys()
        // On a screen, and ordered in. Nothing in this app ever orders a panel out and leaves
        // it so — a pause is a preference the panel draws nothing for, with the window still
        // there — so a panel that is not visible now is one AppKit took away.
        let onScreen = panels.filter { $0.isVisible && $0.screen != nil }.count
        guard Self.wakeNeedsRebuild(screensNow: wanted, screensBefore: built, panelsOnScreen: onScreen) else {
            IslandLog.panel.notice("\(reason, privacy: .public): the island is where it belongs")
            for panel in panels {
                panel.orderFrontRegardless()
                panel.refit()
            }
            return
        }
        IslandLog.panel.error("\(reason, privacy: .public): \(onScreen, privacy: .public) of \(self.panels.count, privacy: .public) panels on screen for \(wanted.count, privacy: .public) displays; rebuilding")
        rebuildPanels(reason: reason)
    }

    /// Whether the displays the panels were built for are still the displays that should
    /// carry one. The one comparison behind both the screen-parameters path and the wake
    /// path: written once, so it cannot be changed in one and stay green in the other.
    static func displaysChanged(now: Set<String>, before: Set<String>) -> Bool {
        now != before
    }

    /// Whether a wake has to rebuild the island: the displays changed while the Mac slept,
    /// which the screen-parameters path would answer the same way, or they did not and a
    /// panel is nonetheless gone from its screen, which nothing else would ever notice.
    ///
    /// No displays at all is a display that has not come back yet, not one that has gone.
    /// The screen-parameters notification that follows will judge that; tearing the panels
    /// down ahead of it would cost a flicker on every lid-open, which is the one thing a
    /// check that runs on every wake must never do.
    static func wakeNeedsRebuild(screensNow: Set<String>, screensBefore: Set<String>, panelsOnScreen: Int) -> Bool {
        guard !screensNow.isEmpty else { return false }
        if displaysChanged(now: screensNow, before: screensBefore) { return true }
        return panelsOnScreen < screensNow.count
    }

    /// The screens that should carry an island right now.
    private static func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        if Preferences.shared.showOnAllDisplays { return screens }
        let notched = screens.filter { $0.safeAreaInsets.top > 0 }
        // With no notch anywhere, the primary display — the one the arrangement puts the
        // menu bar on. Not `NSScreen.main`: that is the display with keyboard focus, and
        // the panels are compared against this on every screen change and wake, so the
        // island hopped to whichever display was last clicked in.
        if notched.isEmpty, let primary = screens.first { return [primary] }
        return notched
    }

    /// The displays the panels were built for, and the ones that should carry a panel now.
    private func displayKeys() -> (built: Set<String>, wanted: Set<String>) {
        let built = Set(panels.map(\.displayKey))
        let wanted = Set(Self.targetScreens().map { NotchPanel.displayKey(for: $0) })
        return (built, wanted)
    }

    /// Rebuilds the panels when the set of displays that should carry one differs from what
    /// is on screen (a display added or removed, or resized, or the menu bar moved to another
    /// display — see `NotchPanel.displayKey`). Returns whether it did.
    @discardableResult
    private func rebuildPanelsIfGeometryChanged() -> Bool {
        let (built, wanted) = displayKeys()
        // No displays at all is a display that has not come back yet, not one that has
        // gone — the same rule `wakeNeedsRebuild` keeps. Building zero panels here tore
        // every island down for the moment a display took to return, and built them again.
        guard !wanted.isEmpty, Self.displaysChanged(now: wanted, before: built) else { return false }
        rebuildPanels(reason: "displays changed")
        return true
    }

    /// Tears every panel down and builds them again for the screens as they are now. Open
    /// to the menu bar as "Reload Island": every competing app's users end up force-quitting
    /// to get their island back, and this is that, without the quit. `reason` is kept, see
    /// `PanelHealth`.
    func rebuildPanels(reason: String) {
        panelHealth.rebuildCount += 1
        panelHealth.lastRebuiltAt = Date()
        panelHealth.lastRebuildReason = reason
        IslandLog.panel.notice("building panels (\(reason, privacy: .public)), build \(self.panelHealth.rebuildCount, privacy: .public) of this run")
        // Whatever the pointer was doing on the old windows, it is not doing on the new.
        ActivityCenter.shared.forgetPointer()
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()

        for screen in Self.targetScreens() {
            let geometry = NotchGeometry.detect(on: screen)
            let panel = NotchPanel(screen: screen, geometry: geometry)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        // Whether every island floats decides where two switches nobody has set start
        // (`FloatingDefaults`), and a rebuild is where that can change. The hub hears it as a
        // preference change, and starts or stops the full-screen watch by the switch as ever.
        Preferences.shared.followFloatingDefaults(panelsFloating: panels.map { !$0.geometry.hasPhysicalNotch })
        ActivityCenter.shared.islandHitTest = { [weak self] point in
            self?.panels.contains { $0.islandContains(screenPoint: point) } ?? false
        }
        ActivityCenter.shared.panelsRebuilt(Set(panels.map(\.panelID)))
    }
}
