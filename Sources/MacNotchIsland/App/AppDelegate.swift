import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panels: [NotchPanel] = []
    private var statusItem: StatusItemController?
    private var hub: ServiceHub?
    private var cancellables = Set<AnyCancellable>()
    private var screenRebuildWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.retireOtherCopies()
        NSApp.setActivationPolicy(.accessory)
        rebuildPanels()
        statusItem = StatusItemController()
        hub = ServiceHub()
        hub?.start()
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
        workspace.addObserver(self, selector: #selector(frontAppChanged),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)

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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ActivityCenter.shared.showHome()
        return false
    }

    /// Two copies (one in /Applications and one still running from a Downloads folder, say)
    /// would draw two islands on the same notch and fight over every click. The copy the user
    /// just launched is the one they want, so any older copy is asked to quit, and made to if
    /// it has not within a moment.
    private static func retireOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        for other in others {
            IslandLog.panel.error("another copy is running (pid \(Int(other.processIdentifier), privacy: .public)); asking it to quit")
            other.terminate()
        }
        guard !others.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for other in others where !other.isTerminated { other.forceTerminate() }
        }
    }

    /// The island belongs to the notch, not to a Space: whatever the user had open stays open
    /// across a swipe, and the panel is put back on top of the new desktop.
    @objc private func spaceChanged() {
        IslandLog.panel.info("space changed")
        for panel in panels {
            panel.orderFrontRegardless()
            panel.refit()
        }
    }

    @objc private func frontAppChanged() {
        for panel in panels { panel.orderFrontRegardless() }
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

    private static func key(for screen: NSScreen, geometry: NotchGeometry) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? ""
        return "screen-\(number)|\(geometry.notchWidth)|\(geometry.notchHeight)"
    }

    /// Rebuilds the panels when the set of screens that should carry one, or a notch's size,
    /// differs from what is on screen. Returns whether it did.
    @discardableResult
    private func rebuildPanelsIfGeometryChanged() -> Bool {
        let current = Set(panels.map { "\($0.panelID)|\($0.geometry.notchWidth)|\($0.geometry.notchHeight)" })
        let fresh = Set(Self.targetScreens().map { Self.key(for: $0, geometry: NotchGeometry.detect(on: $0)) })
        guard current != fresh else { return false }
        IslandLog.panel.info("displays changed; rebuilding panels")
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
    }
}
