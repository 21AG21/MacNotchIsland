import AppKit
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panels: [NotchPanel] = []
    private var statusItem: StatusItemController?
    private var hub: ServiceHub?
    private var cancellables = Set<AnyCancellable>()
    private var screenRebuildWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        RunRecord.begin()
        IslandLog.island.notice("launched pid \(Int(ProcessInfo.processInfo.processIdentifier), privacy: .public) from \(Bundle.main.bundlePath, privacy: .public)")
        catchTermination()
        // Asked to quit here, at the very top, so an older copy has the whole of this launch
        // to go in; nothing it left behind is read until it has.
        let retiring = Self.retireOtherCopies()
        NSApp.setActivationPolicy(.accessory)
        rebuildPanels()
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
            self.hub = ServiceHub()
            self.hub?.start()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { WelcomeWindowController.shared.showIfFirstLaunch() }
        for delay in [5.0, 30.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.rebuildPanelsIfGeometryChanged() }
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
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

        let prefs = Preferences.shared
        Publishers.Merge3(
            prefs.$showOnAllDisplays.dropFirst().map { _ in () },
            prefs.$notchWidthOverride.dropFirst().map { _ in () },
            prefs.$notchHeightOverride.dropFirst().map { _ in () }
        )
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.rebuildPanels() }
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
        for panel in panels { panel.refit() }
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

    /// The screens that should carry an island right now.
    private static func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        if Preferences.shared.showOnAllDisplays { return screens }
        let notched = screens.filter { $0.safeAreaInsets.top > 0 }
        if notched.isEmpty, let main = NSScreen.main { return [main] }
        return notched
    }

    /// Rebuilds the panels when the set of displays that should carry one differs from what
    /// is on screen (a display added or removed, or resized). Returns whether it did.
    @discardableResult
    private func rebuildPanelsIfGeometryChanged() -> Bool {
        let current = Set(panels.map(\.displayKey))
        let fresh = Set(Self.targetScreens().map { NotchPanel.displayKey(for: $0) })
        guard current != fresh else { return false }
        IslandLog.panel.notice("displays changed; rebuilding panels")
        rebuildPanels()
        return true
    }

    private func rebuildPanels() {
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
        ActivityCenter.shared.islandHitTest = { [weak self] point in
            self?.panels.contains { $0.islandContains(screenPoint: point) } ?? false
        }
    }
}
