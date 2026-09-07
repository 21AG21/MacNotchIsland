import Foundation

/// Low Power Mode on/off alert (yellow battery, like iOS).
final class LowPowerMonitor {
    private var token: NSObjectProtocol?
    private var last = false

    func start() {
        guard token == nil else { return }
        last = ProcessInfo.processInfo.isLowPowerModeEnabled
        token = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            let on = ProcessInfo.processInfo.isLowPowerModeEnabled
            guard let self, on != self.last else { return }
            self.last = on
            let custom = CustomActivity(title: "Low Power Mode", subtitle: on ? "On" : "Off", symbol: "battery.50percent",
                                        tint: on ? "yellow" : "white", trailingText: on ? "On" : "Off")
            ActivityCenter.shared.showAlert(IslandActivity(id: "lowpower", kind: .custom, content: .custom(custom), priority: 85))
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
