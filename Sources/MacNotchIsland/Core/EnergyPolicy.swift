import AppKit
import Combine
import IOKit.ps

/// One place that knows whether the Mac is asleep, on battery, or in Low Power Mode, so
/// every animation and poller can slow down or stop. Competitors get 1-star reviews for
/// idling at 5–10% CPU; this is how we stay near zero.
final class EnergyPolicy: ObservableObject {
    static let shared = EnergyPolicy()

    @Published private(set) var isAsleep = false
    @Published private(set) var isLowPower = false
    @Published private(set) var isOnBattery = false

    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var started = false

    private init() {}

    /// True when continuous animation should stop entirely.
    var animationsPaused: Bool {
        Self.animationsPaused(asleep: isAsleep, lowPower: isLowPower, onBattery: isOnBattery,
                               pauseOnBattery: Preferences.shared.pauseAnimationsOnBattery)
    }

    /// Minimum frame interval for continuous animations (visualizer, marquee).
    var animationInterval: TimeInterval {
        Self.animationInterval(asleep: isAsleep, lowPower: isLowPower, onBattery: isOnBattery,
                                pauseOnBattery: Preferences.shared.pauseAnimationsOnBattery)
    }

    /// Multiply timer intervals by this for polling work.
    var pollingMultiplier: Double {
        Self.pollingMultiplier(asleep: isAsleep, lowPower: isLowPower, onBattery: isOnBattery)
    }

    // MARK: Pure rules (unit-testable without touching NSWorkspace/IOKit/Preferences)

    /// Pure form of `animationsPaused`.
    static func animationsPaused(asleep: Bool, lowPower: Bool, onBattery: Bool, pauseOnBattery: Bool) -> Bool {
        asleep || lowPower || (onBattery && pauseOnBattery)
    }

    /// Pure form of `animationInterval`.
    static func animationInterval(asleep: Bool, lowPower: Bool, onBattery: Bool, pauseOnBattery: Bool) -> TimeInterval {
        if animationsPaused(asleep: asleep, lowPower: lowPower, onBattery: onBattery, pauseOnBattery: pauseOnBattery) { return 1 }
        return onBattery ? 1.0 / 20.0 : 1.0 / 30.0
    }

    /// Pure form of `pollingMultiplier`.
    static func pollingMultiplier(asleep: Bool, lowPower: Bool, onBattery: Bool) -> Double {
        if asleep { return 8 }
        if lowPower { return 4 }
        return onBattery ? 2 : 1
    }

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAsleep = true
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAsleep = false
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        })
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let policy = Unmanaged<EnergyPolicy>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { policy.refreshPowerSource() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            powerSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        refreshPowerSource()
    }

    private func refreshPowerSource() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return }
        let onBattery = type == kIOPSBatteryPowerValue
        if onBattery != isOnBattery { isOnBattery = onBattery }
    }
}
