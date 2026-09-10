import AppKit
import IOBluetooth
import IOKit

/// Shows AirPods / headphones / keyboards when they connect, with battery when available.
final class BluetoothMonitor: NSObject {
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        guard running else { return }
        running = false
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard running else { return }
        let name = device.name ?? "Bluetooth Device"
        let address = device.addressString ?? ""
        let symbol = Self.symbol(for: device, name: name)

        if disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }

        var state = BluetoothState(name: name, address: address, symbol: symbol)
        // A compact pill, the way the iPhone announces AirPods: the glyph and the level. The
        // full card with every battery is one click away.
        let show: (BluetoothState) -> Void = { state in
            let activity = IslandActivity(id: "bluetooth", kind: .bluetooth, content: .bluetooth(state), priority: 85)
            ActivityCenter.shared.showAlert(activity, duration: 2.2)
        }

        // Battery levels appear in the IORegistry shortly after connection.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.2) {
            let levels = BluetoothBattery.levels(forAddress: address)
            state.batteryLeft = levels.left
            state.batteryRight = levels.right
            state.batteryCase = levels.caseLevel
            state.batterySingle = levels.single
            DispatchQueue.main.async { show(state) }
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard running else { return }
        let name = device.name ?? "Bluetooth Device"
        let address = device.addressString ?? ""
        let state = BluetoothState(name: name, address: address, symbol: Self.symbol(for: device, name: name), isConnected: false)
        let activity = IslandActivity(id: "bluetooth", kind: .bluetooth, content: .bluetooth(state), priority: 85)
        ActivityCenter.shared.showAlert(activity, duration: 1.8)
        disconnectNotifications[address]?.unregister()
        disconnectNotifications[address] = nil
    }

    // MARK: - Reaching a device again

    /// One paired device, as the island lists it.
    struct Paired: Identifiable, Equatable {
        var name: String
        var address: String
        var symbol: String
        var isConnected: Bool
        /// What the row shows beside the glyph, when the device is awake enough to say.
        var battery: Int? = nil
        var id: String { address }
    }

    /// Everything this Mac has been paired with, connected first and then by name. The reason
    /// this exists: reconnecting a pair of AirPods is a trip to System Settings, and the
    /// island already knows they are there.
    /// What the gallery is shown instead of asking the radio, which it has none of.
    nonisolated(unsafe) static var galleryDevices: [Paired]?

    static func paired() -> [Paired] {
        if let galleryDevices { return galleryDevices }
        let all = BluetoothBattery.cachedLevels()
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { device -> Paired? in
            guard let address = device.addressString, !address.isEmpty else { return nil }
            let name = device.name ?? device.nameOrAddress ?? address
            let connected = device.isConnected()
            // A device in a drawer left its last reading behind in the registry; only ask
            // about the ones that are actually on the other end of the radio.
            var battery: Int?
            if connected, let levels = all[BluetoothBattery.normalised(address)] {
                battery = BluetoothBattery.summary(levels)
            }
            return Paired(name: name, address: address,
                          symbol: symbol(for: device, name: name),
                          isConnected: connected,
                          battery: battery)
        }
        .sorted { a, b in
            if a.isConnected != b.isConnected { return a.isConnected }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Connects or disconnects by address. Both calls block until the radio answers — seconds,
    /// for a device that is asleep in a case — so neither happens on the main thread; the
    /// island's own notifications say what came of it.
    static func setConnected(_ connected: Bool, address: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let device = IOBluetoothDevice(addressString: address) else {
                IslandLog.island.error("no paired device at \(address, privacy: .private)")
                return
            }
            let status = connected ? device.openConnection() : device.closeConnection()
            if status != kIOReturnSuccess {
                IslandLog.island.notice("bluetooth \(connected ? "connect" : "disconnect", privacy: .public) refused: \(status, privacy: .public)")
            }
        }
    }

    static func symbol(for device: IOBluetoothDevice, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if lower.contains("magic keyboard") || lower.contains("keyboard") { return "keyboard.fill" }
        if lower.contains("magic mouse") || lower.contains("mouse") { return "magicmouse.fill" }
        if lower.contains("trackpad") { return "rectangle.fill" }
        if lower.contains("controller") || lower.contains("dualsense") || lower.contains("xbox") { return "gamecontroller.fill" }
        if lower.contains("watch") { return "applewatch" }
        if lower.contains("iphone") { return "iphone" }
        let major = device.deviceClassMajor
        let minor = device.deviceClassMinor
        if major == 0x04 {
            if minor == 0x06 { return "headphones" }
            if minor == 0x01 { return "headphones" }
            return "hifispeaker.fill"
        }
        if major == 0x05 { return "keyboard.fill" }
        return "wave.3.right.circle.fill"
    }
}

/// Reads AirPods / Magic device battery levels from the IORegistry.
enum BluetoothBattery {
    struct Levels {
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        var single: Int?

        var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && single == nil }
    }

    /// The registry writes an address in its own shape, and the radio in another; they only
    /// match once both have been flattened.
    static func normalised(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    /// The single number a list row has room for. A pair of buds is two batteries and the pair
    /// stops working when the emptier one does, so that is the one worth showing — it is what
    /// the iPhone puts on the widget too. The case is deliberately left out: it is not the
    /// thing in your ears. Nothing here touches the radio, so it can be reasoned about.
    static func summary(_ levels: Levels) -> Int? {
        let buds = [usable(levels.left), usable(levels.right)].compactMap { $0 }
        if let lowest = buds.min() { return lowest }
        return usable(levels.single)
    }

    /// A device that is asleep, or that has never been asked, still leaves a number behind —
    /// 0, or something well past full. Only 1 to 100 is a charge.
    private static func usable(_ value: Int?) -> Int? {
        guard let value, (1...100).contains(value) else { return nil }
        return value
    }

    /// Everything the registry has a battery for, keyed by address. The Controls list wants a
    /// level for every row it draws, and one walk answers for all of them; asking device by
    /// device would walk the whole registry once per row.
    static func allLevels() -> [String: Levels] {
        var result: [String: Levels] = [:]

        var iterator: io_iterator_t = 0
        let status = IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
        guard status == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            guard let addrRef = IORegistryEntryCreateCFProperty(entry, "DeviceAddress" as CFString, kCFAllocatorDefault, 0),
                  let addr = addrRef.takeRetainedValue() as? String, !addr.isEmpty else { continue }

            func value(_ key: String) -> Int? {
                guard let ref = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
                return ref.takeRetainedValue() as? Int
            }
            // One device can appear more than once on the way down the tree, each entry
            // carrying part of the picture, so the first answer for a key is kept.
            let key = normalised(addr)
            var levels = result[key] ?? Levels()
            levels.left = levels.left ?? value("BatteryPercentLeft")
            levels.right = levels.right ?? value("BatteryPercentRight")
            levels.caseLevel = levels.caseLevel ?? value("BatteryPercentCase")
            levels.single = levels.single ?? value("BatteryPercentSingle") ?? value("BatteryPercent")
            guard !levels.isEmpty else { continue }
            result[key] = levels
        }
        return result
    }

    static func levels(forAddress address: String) -> Levels {
        guard !address.isEmpty else { return Levels() }
        return allLevels()[normalised(address)] ?? Levels()
    }

    // MARK: - What the list is given

    /// How long a reading is worth reusing. Battery levels move in tens of minutes; the list
    /// asks again every four seconds.
    private static let cacheLifetime: TimeInterval = 15

    /// The last walk, and when it was taken. Read and written on the main thread only — the
    /// background walk hands its result back there rather than writing from under it.
    nonisolated(unsafe) private static var cache: [String: Levels] = [:]
    nonisolated(unsafe) private static var cacheTakenAt: Date?
    nonisolated(unsafe) private static var refreshing = false

    /// What the Controls list draws with. The whole point is that it answers at once: walking
    /// the registry on the main thread every four seconds would be felt in the panel, so the
    /// caller is handed the last walk and a new one is started behind it. The first call has
    /// nothing to hand back, which is fine — the row simply shows no level until it lands.
    static func cachedLevels() -> [String: Levels] {
        let age = cacheTakenAt.map { Date().timeIntervalSince($0) } ?? TimeInterval.greatestFiniteMagnitude
        if age > cacheLifetime, !refreshing {
            refreshing = true
            DispatchQueue.global(qos: .utility).async {
                let fresh = allLevels()
                DispatchQueue.main.async {
                    cache = fresh
                    cacheTakenAt = Date()
                    refreshing = false
                }
            }
        }
        return cache
    }
}
