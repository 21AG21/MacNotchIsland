import AppKit

/// Menu bar extra. The app has no Dock icon, so this is how you reach Settings and Quit.
/// Built like Apple's own extras: a section header that reflects the island's state, items
/// that validate against live state, and an Option-key alternate for the demo menu.
final class StatusItemController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let item: NSStatusItem
    private let header = NSMenuItem.sectionHeader(title: "Notch Island")
    private let visibility = NSMenuItem()
    private let stopwatch = NSMenuItem()
    private let cancel = NSMenuItem()
    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")
            image?.isTemplate = true
            button.image = image
        }
        item.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(header)

        menu.addItem(action("Open Island", #selector(openHome)))
        menu.addItem(.separator())

        let timerMenu = NSMenu()
        for minutes in [1, 3, 5, 10, 15, 25, 45, 60] {
            let it = action(Self.presetTitle(minutes: minutes), #selector(startTimer(_:)))
            it.tag = minutes
            timerMenu.addItem(it)
        }
        timerMenu.addItem(.separator())
        timerMenu.addItem(action("Start Pomodoro", #selector(startPomodoro)))
        cancel.title = "Cancel Timer"
        cancel.action = #selector(cancelTimer)
        cancel.target = self
        timerMenu.addItem(cancel)
        let timerItem = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        stopwatch.action = #selector(toggleStopwatch)
        stopwatch.target = self
        menu.addItem(stopwatch)
        menu.addItem(.separator())

        visibility.target = self
        menu.addItem(visibility)
        menu.addItem(action("Clear Shelf", #selector(clearShelf)))
        menu.addItem(.separator())

        menu.addItem(action("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(action("Copy Diagnostics", #selector(copyDiagnostics)))

        // Hold Option to swap the tour for the demo menu, the way Apple hides advanced options.
        let welcome = action("Welcome Tour", #selector(showWelcome))
        welcome.keyEquivalentModifierMask = []
        menu.addItem(welcome)
        let demoItem = NSMenuItem(title: "Demo", action: nil, keyEquivalent: "")
        demoItem.keyEquivalentModifierMask = .option
        demoItem.isAlternate = true
        demoItem.submenu = buildDemoMenu()
        menu.addItem(demoItem)

        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("About Notch Island", #selector(showAbout)))
        menu.addItem(action("Quit Notch Island", #selector(quit), key: "q"))
        refreshDynamicItems()
        return menu
    }

    private func buildDemoMenu() -> NSMenu {
        let demoMenu = NSMenu()
        let demos: [(String, Selector)] = [
            ("Charging", #selector(demoCharging)),
            ("Low Battery", #selector(demoLowBattery)),
            ("AirPods Connected", #selector(demoAirPods)),
            ("Focus On", #selector(demoFocus)),
            ("Silent Mode", #selector(demoSilent)),
            ("Volume", #selector(demoVolume)),
            ("Unlocked", #selector(demoUnlock)),
            ("Incoming Call", #selector(demoCall)),
            ("Delivery Live Activity", #selector(demoDelivery)),
        ]
        for (title, sel) in demos { demoMenu.addItem(action(title, sel)) }
        demoMenu.addItem(.separator())
        demoMenu.addItem(action("End Demo Activities", #selector(demoEnd)))
        return demoMenu
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        it.target = self
        return it
    }

    static func presetTitle(minutes: Int) -> String {
        if minutes % 60 == 0 { return minutes == 60 ? "1 Hour" : "\(minutes / 60) Hours" }
        return minutes == 1 ? "1 Minute" : "\(minutes) Minutes"
    }

    // MARK: Live state

    func menuNeedsUpdate(_ menu: NSMenu) { refreshDynamicItems() }

    private func refreshDynamicItems() {
        let center = ActivityCenter.shared
        let until = Preferences.shared.pausedUntil
        let paused = until > 0 && Date().timeIntervalSince1970 < until
        if paused {
            header.title = "Hidden until " + timeFormatter.string(from: Date(timeIntervalSince1970: until))
            visibility.title = "Show Island"
            visibility.action = #selector(showNow)
        } else if center.isSuppressed {
            header.title = "Hidden while this app is in front"
            visibility.title = "Hide Island for 1 Hour"
            visibility.action = #selector(hideForHour)
        } else {
            header.title = "Notch Island"
            visibility.title = "Hide Island for 1 Hour"
            visibility.action = #selector(hideForHour)
        }
        stopwatch.title = IslandStopwatch.shared.state == nil ? "Start Stopwatch" : "Reset Stopwatch"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(cancelTimer): return IslandTimer.shared.state != nil
        case #selector(clearShelf): return !ShelfStore.shared.items.isEmpty
        default: return true
        }
    }

    // MARK: Actions

    @objc private func openHome() { ActivityCenter.shared.showHome() }

    @objc private func startTimer(_ sender: NSMenuItem) {
        IslandTimer.shared.start(seconds: TimeInterval(sender.tag * 60), label: "Timer")
    }

    @objc private func startPomodoro() { IslandTimer.shared.startPomodoro() }

    @objc private func cancelTimer() { IslandTimer.shared.cancel() }

    @objc private func toggleStopwatch() {
        if IslandStopwatch.shared.state == nil { IslandStopwatch.shared.start() } else { IslandStopwatch.shared.reset() }
    }

    @objc private func clearShelf() { ShelfStore.shared.clear() }

    @objc private func hideForHour() { ActivityCenter.shared.pause(for: 3600) }

    @objc private func showNow() { ActivityCenter.shared.pause(for: 0) }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func copyDiagnostics() { Diagnostics.copyToPasteboard() }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showWelcome() { WelcomeWindowController.shared.show() }

    @objc private func checkForUpdates() { UpdateChecker.shared.checkNow() }

    // MARK: Demo

    @objc private func demoCharging() {
        ActivityCenter.shared.showAlert(IslandActivity(id: "battery", kind: .battery,
            content: .battery(BatteryState(percent: 82, isCharging: true, isPluggedIn: true, event: .pluggedIn)), priority: 85))
    }

    @objc private func demoLowBattery() {
        ActivityCenter.shared.showAlert(IslandActivity(id: "battery", kind: .battery,
            content: .battery(BatteryState(percent: 10, isCharging: false, isPluggedIn: false, event: .low)),
            priority: 85, presentation: .expanded), duration: 4)
    }

    @objc private func demoAirPods() {
        ActivityCenter.shared.showAlert(IslandActivity(id: "bluetooth", kind: .bluetooth,
            content: .bluetooth(BluetoothState(name: "AirPods Pro", address: "demo", symbol: "airpodspro",
                                               batteryLeft: 92, batteryRight: 88, batteryCase: 64)),
            priority: 85, presentation: .expanded), duration: 4)
    }

    @objc private func demoFocus() {
        ActivityCenter.shared.showAlert(IslandActivity(id: "focus", kind: .focus,
            content: .focus(FocusState(name: "Do Not Disturb", symbol: "moon.fill", isOn: true, tint: "indigo")), priority: 85))
    }

    @objc private func demoSilent() {
        ActivityCenter.shared.showAlert(IslandActivity(id: "silent", kind: .silent,
            content: .silent(SilentState(isSilent: true)), priority: 85), duration: 2)
    }

    @objc private func demoVolume() {
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud,
            content: .hud(LevelHUD(kind: .volume, level: 0.6)), priority: 85), duration: 1.6)
    }

    @objc private func demoUnlock() {
        ActivityCenter.shared.showAlert(IslandActivity(id: "unlock", kind: .unlock, content: .unlock, priority: 85), duration: 1.8)
    }

    @objc private func demoCall() {
        ActivityCenter.shared.upsert(IslandActivity(id: "demo-call", kind: .call,
            content: .call(CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: Date())),
            priority: 100, presentation: .expanded, openAction: .app(bundleID: "com.apple.FaceTime")))
        ActivityCenter.shared.forceExpanded(id: "demo-call", for: 4)
    }

    @objc private func demoDelivery() {
        ActivityCenter.shared.upsert(IslandActivity(id: "demo-delivery", kind: .custom,
            content: .custom(CustomActivity(title: "Order on the way", subtitle: "Arriving in 12 min",
                                            symbol: "bicycle", tint: "green", progress: 0.65,
                                            trailingText: "12 min", body: "Your courier is 1.4 km away.", showsRing: true)),
            priority: 70, expiresAt: Date().addingTimeInterval(600)))
    }

    @objc private func demoEnd() {
        ActivityCenter.shared.end(id: "demo-call")
        ActivityCenter.shared.end(id: "demo-delivery")
        ActivityCenter.shared.dismissAlert()
    }
}
