import Foundation
import IOKit.ps

/// Charging / unplug / low battery / fully charged alerts, driven by IOKit power-source notifications.
final class BatteryMonitor {
    private struct Snapshot: Equatable {
        var pluggedIn: Bool
        var percent: Int
        var charging: Bool
    }

    private var source: CFRunLoopSource?
    private var last: Snapshot?
    private var warnedLow = false
    private var warnedCritical = false
    private var announcedFull = false

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { monitor.refresh() }
        }
        guard let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        last = read()
        if let l = last {
            warnedLow = l.percent <= 20 && !l.pluggedIn
            warnedCritical = l.percent <= 10 && !l.pluggedIn
            announcedFull = l.percent >= 100 && l.pluggedIn
        }
    }

    func stop() {
        if let src = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            source = nil
        }
    }

    private func read() -> Snapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let percent = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
            return Snapshot(pluggedIn: state == kIOPSACPowerValue, percent: percent, charging: charging)
        }
        return nil
    }

    private func refresh() {
        guard let now = read() else { return }
        defer { last = now }
        guard let previous = last else { return }

        if now.pluggedIn && !previous.pluggedIn {
            show(BatteryState(percent: now.percent, isCharging: now.charging, isPluggedIn: true, event: .pluggedIn))
            warnedLow = false
            warnedCritical = false
        } else if !now.pluggedIn && previous.pluggedIn {
            announcedFull = false
            show(BatteryState(percent: now.percent, isCharging: false, isPluggedIn: false, event: .unplugged), duration: 1.8)
        }

        if !now.pluggedIn {
            if now.percent <= 10 && !warnedCritical {
                warnedCritical = true
                warnedLow = true
                show(BatteryState(percent: now.percent, isCharging: false, isPluggedIn: false, event: .critical), duration: 5, expanded: true)
            } else if now.percent <= 20 && !warnedLow {
                warnedLow = true
                show(BatteryState(percent: now.percent, isCharging: false, isPluggedIn: false, event: .low), duration: 4, expanded: true)
            }
        } else if now.percent >= 100 && !announcedFull && previous.percent < 100 {
            announcedFull = true
            show(BatteryState(percent: 100, isCharging: false, isPluggedIn: true, event: .full))
        }
    }

    private func show(_ state: BatteryState, duration: TimeInterval? = nil, expanded: Bool = false) {
        let activity = IslandActivity(id: "battery", kind: .battery, content: .battery(state), priority: 85,
                                      presentation: expanded ? .expanded : .compact)
        ActivityCenter.shared.showAlert(activity, duration: duration)
    }
}
