import Foundation
import CoreMediaIO
import Combine

/// Camera-in-use privacy indicator via CoreMediaIO's "device is running somewhere" property.
///
/// The list of cameras is heard as it changes — CoreMediaIO says when one is plugged in or
/// taken away — and read again every thirty seconds as well, as a net under that.
///
/// None of the asking happens on the main thread. Walking the cameras is a call into the
/// CoreMediaIO server per device, with a listener added to each, and it ran on the main thread
/// at launch, before the island had drawn anything, and then twice a minute for as long as the
/// app ran. The walk, the listeners and every "is it running?" are on `queue` now; the main
/// thread is handed one answer, whether a camera is in use, and only when it changes.
final class CameraMonitor {
    private static let baseInterval: TimeInterval = 30

    /// Where CoreMediaIO is asked, and where its listeners call back. Serial, and the only
    /// place the device list and the listeners are touched.
    private let queue = DispatchQueue(label: "com.macnotchisland.camera", qos: .utility)

    // On `queue`.
    private var devices: [CMIOObjectID] = []
    private var blocks: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []
    /// The listener on the system's list of cameras, kept apart from the per-camera ones:
    /// those are rebuilt on every rescan, and this is what asks for the rescan.
    private var deviceListBlock: CMIOObjectPropertyListenerBlock?
    private var watching = false
    /// Which run of the monitor the queue is serving, handed back with every answer.
    private var ticket = 0

    // On the main thread.
    private var running = false
    /// Bumped on every start and stop, so an answer from a run that has since ended is dropped.
    private var generation = 0
    private var rescanTimer: Timer?
    private var energyCancellable: AnyCancellable?

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        let run = generation
        queue.async { [weak self] in self?.beginWatching(run) }
        scheduleTimer()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        rescanTimer?.invalidate()
        rescanTimer = nil
        energyCancellable?.cancel()
        energyCancellable = nil
        queue.async { [weak self] in self?.endWatching() }
        ActivityCenter.shared.cameraInUse = false
    }

    /// Rebuilds the rescan timer at the current policy interval (device rescans are cheap but
    /// pointless to run at full rate while asleep or in Low Power Mode).
    private func scheduleTimer() {
        guard running else { return }
        let interval = Self.baseInterval * EnergyPolicy.shared.pollingMultiplier
        rescanTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.rescan() }
        }
        t.tolerance = interval * 0.2
        rescanTimer = t
    }

    // MARK: - The queue

    private func beginWatching(_ run: Int) {
        guard !watching else { return }
        watching = true
        ticket = run
        rescan()
        listenForDevices()
    }

    private func endWatching() {
        guard watching else { return }
        watching = false
        stopListeningForDevices()
        removeListeners()
        devices = []
    }

    /// A camera plugged in used to wait for the next rescan to be watched at all — thirty
    /// seconds, two minutes in Low Power Mode — and a call that started on it in the meantime
    /// had no dot. CoreMediaIO says when its list of devices changes, and a change is a rescan
    /// on the spot.
    private func listenForDevices() {
        guard deviceListBlock == nil else { return }
        var address = Self.deviceListAddress
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
        let status = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, block)
        guard status == 0 else {
            IslandLog.island.notice("could not listen for cameras coming and going (\(status, privacy: .public)); the rescan will find them")
            return
        }
        deviceListBlock = block
    }

    private func stopListeningForDevices() {
        guard let block = deviceListBlock else { return }
        var address = Self.deviceListAddress
        _ = CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, block)
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

    private func rescan() {
        guard watching else { return }
        removeListeners()
        devices = allDevices()
        for device in devices {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
            _ = CMIOObjectAddPropertyListenerBlock(device, &address, queue, block)
            blocks.append((device, address, block))
        }
        evaluate()
    }

    private func removeListeners() {
        for (device, addr, block) in blocks {
            var address = addr
            _ = CMIOObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        blocks.removeAll()
    }

    /// Asks every camera whether it is running, here, and hands the one answer to the main
    /// thread, where the island reads it. Compared there, against what the island shows: a
    /// published property is the main thread's to read as well as to write.
    private func evaluate() {
        guard watching else { return }
        let inUse = devices.contains { isRunning($0) }
        let run = ticket
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.generation == run else { return }
            if ActivityCenter.shared.cameraInUse != inUse { ActivityCenter.shared.cameraInUse = inUse }
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
