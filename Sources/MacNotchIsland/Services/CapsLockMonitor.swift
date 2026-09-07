import AppKit

/// Caps Lock on/off pill. Polls NSEvent.modifierFlags, which needs no permission at all.
final class CapsLockMonitor {
    private var timer: Timer?
    private var last = false

    func start() {
        guard timer == nil else { return }
        last = NSEvent.modifierFlags.contains(.capsLock)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.1
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let on = NSEvent.modifierFlags.contains(.capsLock)
        guard on != last else { return }
        last = on
        let custom = CustomActivity(title: "Caps Lock", symbol: on ? "capslock.fill" : "capslock",
                                    tint: on ? "white" : "gray", trailingText: on ? "On" : "Off")
        ActivityCenter.shared.showAlert(IslandActivity(id: "capslock", kind: .custom, content: .custom(custom), priority: 85),
                                        duration: 1.2, haptic: false)
    }
}
