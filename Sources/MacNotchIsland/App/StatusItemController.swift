import AppKit

/// Menu bar item: the app has no Dock icon, so this is how you reach Settings and Quit.
final class StatusItemController: NSObject {
    private let item: NSStatusItem

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

        let open = NSMenuItem(title: "Open Island", action: #selector(openHome), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let timerMenu = NSMenu()
        for minutes in [1, 3, 5, 10, 15, 25, 45, 60] {
            let it = NSMenuItem(title: "\(minutes) min", action: #selector(startTimer(_:)), keyEquivalent: "")
            it.tag = minutes
            it.target = self
            timerMenu.addItem(it)
        }
        timerMenu.addItem(.separator())
        let cancel = NSMenuItem(title: "Cancel Timer", action: #selector(cancelTimer), keyEquivalent: "")
        cancel.target = self
        timerMenu.addItem(cancel)
        let timerItem = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        let clear = NSMenuItem(title: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let demoMenu = NSMenu()
        let demos: [(String, Selector)] = [
            ("Charging", #selector(demoCharging)),
            ("Low battery", #selector(demoLowBattery)),
            ("AirPods connected", #selector(demoAirPods)),
            ("Focus on", #selector(demoFocus)),
            ("Silent mode", #selector(demoSilent)),
            ("Volume", #selector(demoVolume)),
            ("Unlocked", #selector(demoUnlock)),
            ("Incoming call", #selector(demoCall)),
            ("Delivery live activity", #selector(demoDelivery)),
            ("End demo activities", #selector(demoEnd)),
        ]
        for (title, sel) in demos {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            demoMenu.addItem(it)
        }
        let demoItem = NSMenuItem(title: "Demo", action: nil, keyEquivalent: "")
        demoItem.submenu = demoMenu
        menu.addItem(demoItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Notch Island", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    // MARK: Actions

    @objc private func openHome() { ActivityCenter.shared.showHome() }

    @objc private func startTimer(_ sender: NSMenuItem) {
        IslandTimer.shared.start(seconds: TimeInterval(sender.tag * 60), label: "Timer")
    }

    @objc private func cancelTimer() { IslandTimer.shared.cancel() }

    @objc private func clearShelf() { ShelfStore.shared.clear() }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

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
