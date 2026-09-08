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
    }

    static func levels(forAddress address: String) -> Levels {
        var result = Levels()
        guard !address.isEmpty else { return result }
        let target = address.lowercased().replacingOccurrences(of: ":", with: "-")

        var iterator: io_iterator_t = 0
        let status = IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
        guard status == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            guard let addrRef = IORegistryEntryCreateCFProperty(entry, "DeviceAddress" as CFString, kCFAllocatorDefault, 0),
                  let addr = addrRef.takeRetainedValue() as? String else { continue }
            guard addr.lowercased().replacingOccurrences(of: ":", with: "-") == target else { continue }

            func value(_ key: String) -> Int? {
                guard let ref = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
                return ref.takeRetainedValue() as? Int
            }
            result.left = result.left ?? value("BatteryPercentLeft")
            result.right = result.right ?? value("BatteryPercentRight")
            result.caseLevel = result.caseLevel ?? value("BatteryPercentCase")
            result.single = result.single ?? value("BatteryPercentSingle") ?? value("BatteryPercent")
            if result.left != nil || result.single != nil { break }
        }
        return result
    }
}
