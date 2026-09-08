import Foundation
import IOKit
import IOKit.ps

/// Charging / unplug / low battery / fully charged alerts, driven by IOKit power-source notifications.
final class BatteryMonitor {
    private struct Snapshot: Equatable {
        var pluggedIn: Bool
        var percent: Int
        var charging: Bool
    }

    /// Cycle count, health, temperature and live power draw off the IORegistry's AppleSmartBattery node.
    struct SmartBatteryInfo: Equatable {
        var cycleCount: Int? = nil
        var healthPercent: Int? = nil
        var temperatureCelsius: Double? = nil
        /// Signed watts, positive while charging.
        var wattage: Double? = nil
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

    /// The power-source description of the internal battery, or nil on a Mac without one.
    /// Shared with `SystemStats`, which asks the same question for the Stats section.
    static func internalBatteryDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType { return desc }
        }
        return nil
    }

    private func read() -> Snapshot? {
        guard let desc = Self.internalBatteryDescription() else { return nil }
        let percent = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        return Snapshot(pluggedIn: state == kIOPSACPowerValue, percent: percent, charging: charging)
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
                show(BatteryState(percent: now.percent, isCharging: false, isPluggedIn: false, event: .critical), duration: 4)
            } else if now.percent <= 20 && !warnedLow {
                warnedLow = true
                show(BatteryState(percent: now.percent, isCharging: false, isPluggedIn: false, event: .low), duration: 3)
            }
        } else if now.percent >= 100 && !announcedFull && previous.percent < 100 {
            announcedFull = true
            show(BatteryState(percent: 100, isCharging: false, isPluggedIn: true, event: .full))
        }
    }

    private func show(_ state: BatteryState, duration: TimeInterval? = nil, expanded: Bool = false) {
        let activity = IslandActivity(id: "battery", kind: .battery, content: .battery(Self.detailed(state)), priority: 85,
                                      presentation: expanded ? .expanded : .compact)
        ActivityCenter.shared.showAlert(activity, duration: duration)
    }

    // MARK: - Detail

    /// The state with its time estimate and IORegistry figures filled in. Read here, as a
    /// state is about to be shown, rather than on every power-source callback.
    static func detailed(_ state: BatteryState) -> BatteryState {
        var filled = state
        filled.timeRemainingMinutes = readTimeRemaining(pluggedIn: state.isPluggedIn, charging: state.isCharging)
        if let reading = readSmartBattery() {
            filled.wattage = reading.wattage
            filled.cycleCount = reading.cycleCount
            filled.healthPercent = reading.healthPercent
            filled.temperatureCelsius = reading.temperatureCelsius
        }
        return filled
    }

    /// Minutes to full while charging, or to empty on battery. Nil while macOS is still
    /// estimating, and nil on power when nothing is charging: there is nothing to count down.
    static func readTimeRemaining(pluggedIn: Bool, charging: Bool) -> Int? {
        if pluggedIn {
            guard charging else { return nil }
            return knownMinutes(internalBatteryDescription()?[kIOPSTimeToFullChargeKey])
        }
        // Seconds, with kIOPSTimeRemainingUnknown (-1) while the estimate settles and
        // kIOPSTimeRemainingUnlimited (-2) on power.
        if let estimate = minutes(fromSeconds: IOPSGetTimeRemainingEstimate()) { return estimate }
        return knownMinutes(internalBatteryDescription()?[kIOPSTimeToEmptyKey])
    }

    /// A minutes figure straight from the power-source description, where -1 means unknown.
    static func knownMinutes(_ value: Any?) -> Int? {
        guard let minutes = value as? Int, minutes >= 0 else { return nil }
        return minutes
    }

    /// Everything the AppleSmartBattery IORegistry node will say. Nil on a Mac without a battery.
    static func readSmartBattery() -> SmartBatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propertiesRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = propertiesRef?.takeRetainedValue() as? [String: Any] else { return nil }
        return info(from: properties)
    }

    /// The decoding behind `readSmartBattery`, split out so it can be tested against a plain dictionary.
    static func info(from properties: [String: Any]) -> SmartBatteryInfo {
        func int(_ key: String) -> Int? {
            // int64Value rather than `as? Int`: a negative Amperage can arrive as an unsigned
            // 64-bit number that `as? Int` refuses, and its two's-complement reading is the right one.
            guard let number = properties[key] as? NSNumber else { return nil }
            return Int(number.int64Value)
        }

        var reading = SmartBatteryInfo()
        if let cycles = int("CycleCount"), cycles >= 0, cycles < 1_000_000 {
            reading.cycleCount = cycles
        }
        if let design = int("DesignCapacity"), design > 0 {
            // AppleRawMaxCapacity is the honest mAh figure; MaxCapacity is the fallback for
            // machines that do not publish the raw one.
            if let raw = int("AppleRawMaxCapacity") {
                reading.healthPercent = healthPercent(maxCapacity: raw, designCapacity: design)
            } else if let health = int("MaxCapacity").flatMap({ healthPercent(maxCapacity: $0, designCapacity: design) }),
                      health >= 40 {
                // Some Apple silicon models publish MaxCapacity as a bare percentage; a ratio no
                // working battery could have means the units did not match, so say nothing.
                reading.healthPercent = health
            }
        }
        if let raw = int("Temperature") {
            reading.temperatureCelsius = celsius(fromRawTemperature: raw)
        }
        if let amperage = int("Amperage"), let voltage = int("Voltage"), voltage > 0 {
            reading.wattage = wattage(amperageMilliamps: signedAmperage(amperage), voltageMillivolts: voltage)
        }
        return reading
    }

    // MARK: - Pure helpers

    /// `IOPSGetTimeRemainingEstimate` seconds as whole minutes; nil for its negative sentinels.
    static func minutes(fromSeconds seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0, seconds < 1_000_000_000 else { return nil }
        return Int(seconds / 60)
    }

    /// Apple silicon hands a negative Amperage back wrapped into an unsigned 32-bit value.
    static func signedAmperage(_ raw: Int) -> Int {
        raw > 0x7FFF_FFFF ? raw - 0x1_0000_0000 : raw
    }

    /// Signed watts from the battery's milliamps and millivolts; positive while charging.
    static func wattage(amperageMilliamps: Int, voltageMillivolts: Int) -> Double {
        Double(amperageMilliamps) / 1000 * Double(voltageMillivolts) / 1000
    }

    /// Full-charge capacity as a whole percentage of design capacity, clamped to 0...100.
    /// Nil when the design figure is missing (zero), since the ratio would mean nothing.
    static func healthPercent(maxCapacity: Int, designCapacity: Int) -> Int? {
        guard designCapacity > 0 else { return nil }
        let ratio = Double(maxCapacity) / Double(designCapacity) * 100
        return Int(min(100, max(0, ratio.rounded())))
    }

    /// AppleSmartBattery's Temperature is in hundredths of a degree (3012 is 30.12 °C).
    /// Firmware that counts in hundredths of a kelvin instead gives a figure no battery
    /// could survive as Celsius, so that reading is recognised and converted.
    static func celsius(fromRawTemperature raw: Int) -> Double? {
        guard raw > 0 else { return nil }
        let degrees = Double(raw) / 100
        return degrees > 200 ? degrees - 273.15 : degrees
    }
}
