import AppKit
import Combine

/// Caps Lock on/off pill. Polls NSEvent.modifierFlags, which needs no permission at all.
final class CapsLockMonitor {
    private static let baseInterval: TimeInterval = 0.6

    private var timer: Timer?
    private var last = false
    private var energyCancellable: AnyCancellable?

    func start() {
        guard timer == nil else { return }
        last = NSEvent.modifierFlags.contains(.capsLock)
        scheduleTimer()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        energyCancellable?.cancel()
        energyCancellable = nil
    }

    /// Rebuilds the poll timer at the current policy interval. Base rate is 0.2s (5 Hz); the
    /// heaviest multiplier (asleep, 8x) brings that to 1.6s — comfortably under the 2 Hz cap.
    private func scheduleTimer() {
        let interval = Self.baseInterval * EnergyPolicy.shared.pollingMultiplier
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = interval * 0.25
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
