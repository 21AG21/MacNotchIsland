import Foundation
import CoreMediaIO

/// Camera-in-use privacy indicator via CoreMediaIO's "device is running somewhere" property.
final class CameraMonitor {
    private var devices: [CMIOObjectID] = []
    private var blocks: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []
    private var running = false
    private var rescanTimer: Timer?

    func start() {
        guard !running else { return }
        running = true
        rescan()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.rescan() }
    }

    func stop() {
        guard running else { return }
        running = false
        rescanTimer?.invalidate()
        rescanTimer = nil
        removeListeners()
        ActivityCenter.shared.cameraInUse = false
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
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
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
