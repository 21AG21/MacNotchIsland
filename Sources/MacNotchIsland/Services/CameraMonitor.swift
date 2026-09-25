import Foundation
import CoreMediaIO
import Combine

/// Camera-in-use privacy indicator via CoreMediaIO's "device is running somewhere" property.
///
/// The list of cameras is heard as it changes — CoreMediaIO says when one is plugged in or
/// taken away — and read again every thirty seconds as well, as a net under that.
final class CameraMonitor {
    private static let baseInterval: TimeInterval = 30

    private var devices: [CMIOObjectID] = []
    private var blocks: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []
    /// The listener on the system's list of cameras, kept apart from the per-camera ones:
    /// those are rebuilt on every rescan, and this is what asks for the rescan.
    private var deviceListBlock: CMIOObjectPropertyListenerBlock?
    private var running = false
    private var rescanTimer: Timer?
    private var energyCancellable: AnyCancellable?

    func start() {
        guard !running else { return }
        running = true
        rescan()
        listenForDevices()
        scheduleTimer()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
    }

    func stop() {
        guard running else { return }
        running = false
        rescanTimer?.invalidate()
        rescanTimer = nil
        energyCancellable?.cancel()
        energyCancellable = nil
        stopListeningForDevices()
        removeListeners()
        ActivityCenter.shared.cameraInUse = false
    }

    /// A camera plugged in used to wait for the next rescan to be watched at all — thirty
    /// seconds, two minutes in Low Power Mode — and a call that started on it in the meantime
    /// had no dot. CoreMediaIO says when its list of devices changes, and a change is a rescan
    /// on the spot.
    private func listenForDevices() {
        guard deviceListBlock == nil else { return }
        var address = Self.deviceListAddress
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.rescan()
        }
        let status = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, DispatchQueue.main, block)
        guard status == 0 else {
            IslandLog.island.notice("could not listen for cameras coming and going (\(status, privacy: .public)); the rescan will find them")
            return
        }
        deviceListBlock = block
    }

    private func stopListeningForDevices() {
        guard let block = deviceListBlock else { return }
        var address = Self.deviceListAddress
        _ = CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, DispatchQueue.main, block)
        deviceListBlock = nil
    }

    /// The system object's list of devices, which is both what is read for the cameras and
    /// what is listened to for a change in them.
    private static var deviceListAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    /// Rebuilds the rescan timer at the current policy interval (device rescans are cheap but
    /// pointless to run at full rate while asleep or in Low Power Mode).
    private func scheduleTimer() {
        guard running else { return }
        let interval = Self.baseInterval * EnergyPolicy.shared.pollingMultiplier
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.rescan() }
    }

    private func rescan() {
        removeListeners()
        devices = allDevices()
        for device in devices {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
            _ = CMIOObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
            blocks.append((device, address, block))
        }
        evaluate()
    }

    private func removeListeners() {
        for (device, addr, block) in blocks {
            var address = addr
            _ = CMIOObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
        blocks.removeAll()
    }

    private func evaluate() {
        let inUse = devices.contains { isRunning($0) }
        if ActivityCenter.shared.cameraInUse != inUse {
            DispatchQueue.main.async { ActivityCenter.shared.cameraInUse = inUse }
        }
    }

    private func allDevices() -> [CMIOObjectID] {
        var address = Self.deviceListAddress
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, &ids) == 0 else { return [] }
        return ids
    }

    private func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &value) == 0 else { return false }
        return value != 0
    }
}
