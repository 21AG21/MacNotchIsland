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

    @objc private func screensChanged() {
        // didChangeScreenParameters fires several times per physical event; rebuild once.
        screenRebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildPanels() }
        screenRebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func rebuildPanelsIfGeometryChanged() {
        let current = Set(panels.map { "\($0.panelID)|\($0.geometry.notchWidth)|\($0.geometry.notchHeight)" })
        let fresh = Set(NSScreen.screens.map { screen -> String in
            let g = NotchGeometry.detect(on: screen)
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? ""
            return "screen-\(number)|\(g.notchWidth)|\(g.notchHeight)"
        })
        if !current.isSubset(of: fresh) { rebuildPanels() }
    }

    private func rebuildPanels() {
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()

        let screens = NSScreen.screens
        let targets: [NSScreen]
        if Preferences.shared.showOnAllDisplays {
            targets = screens
        } else {
            let notched = screens.filter { $0.safeAreaInsets.top > 0 }
            if notched.isEmpty, let main = NSScreen.main {
                targets = [main]
            } else {
                targets = notched
            }
        }

        for screen in targets {
            let geometry = NotchGeometry.detect(on: screen)
            let panel = NotchPanel(screen: screen, geometry: geometry)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
}
