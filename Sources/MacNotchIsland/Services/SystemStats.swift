import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Live CPU / memory / network / battery-health numbers for the Home panel's Stats tab.
///
/// Everything in here is public API that needs no entitlement and no permission prompt:
/// Mach host statistics for CPU and memory, `getifaddrs` for the interface byte counters,
/// and the IORegistry's `AppleSmartBattery` node for health, cycles and temperature.
///
/// Sampling only runs while a view is on screen — `start()` / `stop()` are reference
/// counted — and the cadence follows `EnergyPolicy`, so a closed panel costs nothing.
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    /// One reading of the machine. The battery fields are nil on desktops.
    struct Sample: Equatable {
        var cpuPercent: Double = 0
        var memoryUsedBytes: UInt64 = 0
        var memoryTotalBytes: UInt64 = 0
        var networkDownBytesPerSec: Double = 0
        var networkUpBytesPerSec: Double = 0
        var batteryHealthPercent: Double?
        var cycleCount: Int?
        var batteryTemperatureC: Double?
        var diskUsedBytes: UInt64 = 0
        var diskTotalBytes: UInt64 = 0
        /// What a laptop is actually asked about: how much charge is left, and for how long.
        var batteryPercent: Int?
        var batteryCharging = false
        var batteryMinutesRemaining: Int?
    }

    @Published private(set) var sample = Sample()
    /// The last `historyLength` CPU readings, oldest first — the sparkline's data.
    @Published private(set) var cpuHistory: [Double] = []
    /// The same window of network throughput (down plus up, bytes a second).
    @Published private(set) var networkHistory: [Double] = []
    /// True while at least one view is asking for samples.
    private(set) var isRunning = false

    /// How many CPU readings the sparkline keeps.
    static let historyLength = 40
    private static let baseInterval: TimeInterval = 2
    /// The first reading can only establish the CPU / network baselines, so follow it up
    /// quickly instead of leaving the panel at 0% for a whole interval.
    private static let primingDelay: TimeInterval = 0.4
    /// How long a battery reading is good for; health and cycles barely move.
    private static let batteryInterval: TimeInterval = 30
    /// The same for the disk: free space moves slowly and the reading walks the volume.
    private static let diskInterval: TimeInterval = 30

    /// The host port is a send right that `mach_host_self()` re-references on every call,
    /// so take it once instead of every two seconds.
    private static let hostPort: host_t = mach_host_self()

    private let queue = DispatchQueue(label: "com.notchisland.systemstats", qos: .utility)
    private var subscribers = 0
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var energyCancellable: AnyCancellable?

    // Touched on `queue` only.
    private var sampling = false
    private var previousCPU: (busy: UInt64, total: UInt64)?
    private var previousNetwork: (down: UInt64, up: UInt64, time: Date)?
    private var battery: (health: Double?, cycles: Int?, temperature: Double?)?
    private var batteryReadAt: Date?
    private var disk: (used: UInt64, total: UInt64)?
    private var diskReadAt: Date?

    private init() {}

    // MARK: - The gallery

    /// A Mac at work, for the rendered gallery. Sampling on the machine that renders it puts
    /// an idle runner's zeroes on screen and leaves every trace empty, so the section can
    /// only be reviewed as five em dashes. Does nothing outside the gallery.
    func seedForGallery() {
        guard RenderMode.isGallery else { return }
        sample = Sample(cpuPercent: 23,
                        memoryUsedBytes: 18_400_000_000, memoryTotalBytes: 24_000_000_000,
                        networkDownBytesPerSec: 1_480_000, networkUpBytesPerSec: 96_000,
                        batteryHealthPercent: 97, cycleCount: 112, batteryTemperatureC: 31,
                        diskUsedBytes: 604_000_000_000, diskTotalBytes: 1_000_000_000_000,
                        batteryPercent: 82, batteryCharging: false, batteryMinutesRemaining: 220)
        cpuHistory = (0..<Self.historyLength).map { i in
            let t = Double(i)
            return max(0, 14 + 9 * sin(t / 3.1) + 5 * sin(t / 1.3))
        }
        networkHistory = (0..<Self.historyLength).map { i in
            let t = Double(i)
            return max(0, 320_000 + 900_000 * sin(t / 4.7) + 300_000 * sin(t / 1.9))
        }
    }

    // MARK: - Lifecycle

    /// Balanced with `stop()`. Safe to nest: only the first call starts the timer.
    func start() {
        // The gallery is handed its numbers; sampling would only take them away again.
        guard !RenderMode.isGallery else { return }
        subscribers += 1
        guard subscribers == 1 else { return }
        isRunning = true

        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rescheduleTimer() }
        rescheduleTimer()

        queue.async { [weak self] in
            guard let self else { return }
            self.sampling = true
            // Rates are only meaningful over a fresh window; a stale baseline from the
            // last time the panel was open would produce a nonsense first number.
            self.previousCPU = nil
            self.previousNetwork = nil
            self.takeSample()
        }
        queue.asyncAfter(deadline: .now() + Self.primingDelay) { [weak self] in self?.takeSample() }
    }

    /// Balanced with `start()`. Sampling stops entirely once the last caller has gone.
    func stop() {
        guard !RenderMode.isGallery else { return }
        guard subscribers > 0 else { return }
        subscribers -= 1
        guard subscribers == 0 else { return }
        isRunning = false

        timer?.invalidate()
        timer = nil
        timerInterval = 0
        energyCancellable?.cancel()
        energyCancellable = nil
        cpuHistory = []
        networkHistory = []
        queue.async { [weak self] in self?.sampling = false }
    }

    private var interval: TimeInterval {
        Self.baseInterval * max(1, EnergyPolicy.shared.pollingMultiplier)
    }

    /// Rebuilds the timer whenever the energy policy asks for a different cadence.
    private func rescheduleTimer() {
        guard isRunning else { return }
        let wanted = interval
        guard timer == nil || abs(wanted - timerInterval) > 0.01 else { return }
        timer?.invalidate()
        timerInterval = wanted
        let scheduled = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.queue.async { [weak self] in self?.takeSample() }
        }
        scheduled.tolerance = wanted * 0.3
        timer = scheduled
    }

    // MARK: - Sampling (on `queue`)

    private func takeSample() {
        guard sampling else { return }
        let now = Date()
        var next = Sample()
        var recordCPU = false

        if let ticks = Self.readCPUTicks() {
            if let previous = previousCPU {
                next.cpuPercent = Self.cpuPercent(previous: previous, current: ticks)
                recordCPU = true
            }
            previousCPU = ticks
        }

        if let memory = Self.readMemory() {
            next.memoryUsedBytes = memory.used
            next.memoryTotalBytes = memory.total
        }

        if let counters = Self.readNetworkCounters() {
            if let previous = previousNetwork {
                let elapsed = now.timeIntervalSince(previous.time)
                next.networkDownBytesPerSec = Self.rate(bytesNow: counters.down, bytesBefore: previous.down, elapsed: elapsed)
                next.networkUpBytesPerSec = Self.rate(bytesNow: counters.up, bytesBefore: previous.up, elapsed: elapsed)
            }
            previousNetwork = (counters.down, counters.up, now)
        }

        let reading = batteryReading(now: now)
        next.batteryHealthPercent = reading.health
        next.cycleCount = reading.cycles
        next.batteryTemperatureC = reading.temperature

        if let disk = diskReading(now: now) {
            next.diskUsedBytes = disk.used
            next.diskTotalBytes = disk.total
        }

        if let charge = Self.readCharge() {
            next.batteryPercent = charge.percent
            next.batteryCharging = charge.charging
            next.batteryMinutesRemaining = charge.minutes
        }

        publish(next, recordCPU: recordCPU)
    }

    /// The IORegistry lookup is the expensive half of a sample and battery health moves
    /// in months, so it only needs re-reading now and then.
    private func batteryReading(now: Date) -> (health: Double?, cycles: Int?, temperature: Double?) {
        if let cached = battery, let readAt = batteryReadAt, now.timeIntervalSince(readAt) < Self.batteryInterval {
            return cached
        }
        let reading = Self.readBattery()
        battery = reading
        batteryReadAt = now
        return reading
    }

    /// How much charge is left, whether it is going up, and macOS's own estimate of how long
    /// it will last — the three things a laptop is asked about. Nil on a desktop.
    static func readCharge() -> (percent: Int, charging: Bool, minutes: Int?)? {
        guard let description = BatteryMonitor.internalBatteryDescription() else { return nil }
        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let raw = description[key] as? Int ?? -1
        let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
        // macOS reports -1 while it is still working the estimate out.
        return (min(100, max(0, percent)), charging, raw > 0 ? raw : nil)
    }

    /// Free space on the boot volume. Cached like the battery: the answer walks the volume
    /// and barely changes between samples.
    private func diskReading(now: Date) -> (used: UInt64, total: UInt64)? {
        if let cached = disk, let readAt = diskReadAt, now.timeIntervalSince(readAt) < Self.diskInterval {
            return cached
        }
        let reading = Self.readDisk()
        disk = reading
        diskReadAt = now
        return reading
    }

    /// Used and total bytes on the volume the system booted from, or nil when it cannot be
    /// read. "Available" is the figure Finder shows — what could be freed for a big write.
    static func readDisk() -> (used: UInt64, total: UInt64)? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                             .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? 0
        let capacity = UInt64(total)
        return (capacity - min(capacity, available), capacity)
    }

    private func publish(_ new: Sample, recordCPU: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            if self.sample != new { self.sample = new }
            guard recordCPU else { return }
            self.cpuHistory = Self.appending(new.cpuPercent, to: self.cpuHistory)
            self.networkHistory = Self.appending(new.networkDownBytesPerSec + new.networkUpBytesPerSec,
                                                 to: self.networkHistory)
        }
    }

    /// One more reading, keeping the window at `historyLength`.
    static func appending(_ value: Double, to history: [Double]) -> [Double] {
        var next = history
        next.append(value)
        if next.count > historyLength { next.removeFirst(next.count - historyLength) }
        return next
    }

    // MARK: - CPU

    /// Aggregate busy / total CPU ticks across every core, or nil when Mach says no.
    static func readCPUTicks() -> (busy: UInt64, total: UInt64)? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(hostPort, processor_flavor_t(PROCESSOR_CPU_LOAD_INFO),
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let ticks = info else { return nil }
        defer {
            let address = UInt(bitPattern: UnsafeRawPointer(ticks))
            vm_deallocate(mach_task_self_, vm_address_t(address),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        guard states > 0, Int(infoCount) >= Int(cpuCount) * states else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for core in 0..<Int(cpuCount) {
            let base = core * states
            // The ticks are unsigned in the kernel's struct but come back through a signed
            // array, so read them out of their bit pattern.
            let user = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_IDLE)]))
            busy &+= user &+ system &+ nice
            total &+= user &+ system &+ nice &+ idle
        }
        return (busy, total)
    }

    /// Busy share of two tick readings, 0–100. Zero when the counters did not move or
    /// went backwards (a wrap, or a fresh baseline).
    static func cpuPercent(previous: (busy: UInt64, total: UInt64), current: (busy: UInt64, total: UInt64)) -> Double {
        guard current.total > previous.total, current.busy >= previous.busy else { return 0 }
        let totalDelta = Double(current.total - previous.total)
        let busyDelta = Double(current.busy - previous.busy)
        guard totalDelta > 0 else { return 0 }
        return min(100, max(0, busyDelta / totalDelta * 100))
    }

    // MARK: - Memory

    /// Used / total physical memory in bytes. "Used" is the figure Activity Monitor's
    /// memory pressure is about: active + wired + compressed pages.
    static func readMemory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { rebound -> kern_return_t in
                host_statistics64(hostPort, host_flavor_t(HOST_VM_INFO64), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(max(4096, sysconf(_SC_PAGESIZE)))
        let pages = UInt64(stats.active_count) &+ UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        return (min(pages &* pageSize, total), total)
    }

    // MARK: - Network

    /// Total bytes in / out across the Ethernet-family interfaces ("en0" is Wi-Fi on a
    /// laptop, "en1" and up the Thunderbolt / USB adapters).
    static func readNetworkCounters() -> (down: UInt64, up: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var down: UInt64 = 0
        var up: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            // Only the link-level entry carries byte counters; the AF_INET / AF_INET6
            // aliases of the same interface would double count.
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
            guard let raw = entry.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self)
            down &+= UInt64(data.pointee.ifi_ibytes)
            up &+= UInt64(data.pointee.ifi_obytes)
        }
        return (down, up)
    }

    /// Bytes per second between two counter readings. Zero on a wrap (the kernel's
    /// per-interface counters are 32-bit) or a bad window.
    static func rate(bytesNow: UInt64, bytesBefore: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, elapsed.isFinite, bytesNow >= bytesBefore else { return 0 }
        return Double(bytesNow - bytesBefore) / elapsed
    }

    // MARK: - Battery

    /// Health / cycles / temperature straight off the AppleSmartBattery IORegistry node.
    /// All nil on a Mac without a battery.
    static func readBattery() -> (health: Double?, cycles: Int?, temperature: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }

        func number(_ key: String) -> Double? {
            guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
            return (ref.takeRetainedValue() as? NSNumber)?.doubleValue
        }

        // AppleRawMaxCapacity is the honest mAh figure; MaxCapacity is the fallback for
        // machines that do not publish the raw one.
        let maxCapacity = number("AppleRawMaxCapacity") ?? number("MaxCapacity")
        let design = number("DesignCapacity")
        // Some Apple Silicon models publish MaxCapacity as a percentage rather than mAh; a
        // ratio far below any real battery's health means the units didn't match.
        let health = healthPercent(max: maxCapacity ?? 0, design: design ?? 0).flatMap { $0 >= 40 ? $0 : nil }
        // Never force a nonsense double through Int(), which would trap.
        let cycles = number("CycleCount").flatMap { (raw: Double) -> Int? in
            guard raw.isFinite, raw >= 0, raw < 1_000_000 else { return nil }
            return Int(raw)
        }
        let temperature = number("Temperature").flatMap { celsius(fromRawTemperature: $0) }
        return (health, cycles, temperature)
    }

    /// Full-charge capacity as a percentage of the design capacity, nil when either
    /// number is missing or zero (desktops, or a battery that will not answer).
    static func healthPercent(max: Double, design: Double) -> Double? {
        guard max > 0, design > 0, max.isFinite, design.isFinite else { return nil }
        return max / design * 100
    }

    /// AppleSmartBattery reports "Temperature" in hundredths of a degree: Celsius on Apple
    /// silicon (3062 → 30.62 °C), kelvin on some older firmware (30415 → 31 °C). No battery
    /// runs above 200 °C, so anything that high is a kelvin reading.
    static func celsius(fromRawTemperature raw: Double) -> Double? {
        guard raw > 0, raw.isFinite else { return nil }
        let degrees = raw / 100
        return degrees > 200 ? degrees - 273.15 : degrees
    }

    // MARK: - Formatting

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    /// Sizes as the Finder writes them ("412 GB"), shared by the memory and disk cells.
    static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useGB]
        return formatter
    }()

    /// "1.2 MB/s". Anything negative or not-a-number reads as zero.
    static func rateText(_ bytesPerSecond: Double) -> String {
        let clamped = bytesPerSecond.isFinite ? Swift.max(0, bytesPerSecond) : 0
        let bytes = clamped >= Double(Int64.max) ? Int64.max : Int64(clamped.rounded())
        return byteFormatter.string(fromByteCount: bytes) + "/s"
    }

    /// "12.4 / 16 GB" — the used figure drops its unit when it matches the total's.
    static func memoryText(used: UInt64, total: UInt64) -> String {
        let usedText = memoryFormatter.string(fromByteCount: Int64(clamping: used))
        let totalText = memoryFormatter.string(fromByteCount: Int64(clamping: total))
        let usedParts = usedText.split(separator: " ")
        let totalParts = totalText.split(separator: " ")
        if usedParts.count == 2, totalParts.count == 2, usedParts[1] == totalParts[1] {
            return "\(usedParts[0]) / \(totalText)"
        }
        return "\(usedText) / \(totalText)"
    }
}
