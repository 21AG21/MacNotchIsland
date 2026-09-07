import AppKit
import Combine

/// Brightness HUD. There is no public change notification, so the built-in display's
/// brightness is sampled a few times a second through DisplayServices (cheap call).
/// The same private symbols also let the media-key interceptor set the brightness when
/// it replaces the system bezel.
final class BrightnessMonitor {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// DisplayServices is resolved once for the whole process: the monitor started by the
    /// service hub and the media-key interceptor both go through it.
    private static let symbols: (get: GetBrightnessFn?, set: SetBrightnessFn?) = BrightnessMonitor.loadSymbols()

    private static func loadSymbols() -> (get: GetBrightnessFn?, set: SetBrightnessFn?) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else {
            NSLog("Notch Island: DisplayServices is unavailable; the brightness HUD is disabled.")
            return (nil, nil)
        }
        var get: GetBrightnessFn?
        var set: SetBrightnessFn?
        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            get = unsafeBitCast(sym, to: GetBrightnessFn.self)
        }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            set = unsafeBitCast(sym, to: SetBrightnessFn.self)
        }
        if get == nil || set == nil {
            NSLog("Notch Island: DisplayServices brightness symbols are missing (get: \(get != nil), set: \(set != nil)).")
        }
        return (get, set)
    }

    /// Last value reported to the island. Shared so a value we set ourselves is not
    /// announced twice (once by the setter, once by the poll). Main thread only.
    private static var lastSeen: Float = -1

    private var timer: Timer?

    private var energyCancellable: AnyCancellable?

    func start() {
        guard timer == nil, Self.symbols.get != nil else { return }
        Self.lastSeen = read() ?? -1
        scheduleTimer()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
    }

    /// 4 Hz on mains power (brightness keys repeat quickly), slower on battery / Low Power / asleep.
    private func scheduleTimer() {
        timer?.invalidate()
        let interval = 0.25 * EnergyPolicy.shared.pollingMultiplier
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = interval * 0.2
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        energyCancellable = nil
    }

    // MARK: Reading / writing

    /// Brightness of the built-in display, 0...1, or nil when it cannot be read.
    func currentBrightness() -> Float? { read() }

    /// Sets the brightness of the built-in display. Returns false when the write failed.
    @discardableResult
    func setBrightness(_ value: Float) -> Bool {
        guard let fn = Self.symbols.set else { return false }
        let clamped = max(0, min(1, value))
        let status = fn(builtInDisplay, clamped)
        if status != 0 {
            NSLog("Notch Island: could not set brightness (status \(status)).")
            return false
        }
        return true
    }

    /// Shows the brightness HUD right away (used after we set the value ourselves) and
    /// marks the value as seen so the poll does not report it a second time. Pass the
    /// value that was just written when the display may not report it back instantly.
    func notifyChange(value: Float? = nil) {
        guard let v = value ?? read() else { return }
        Self.lastSeen = v
        post(v)
    }

    // MARK: Internals

    private var builtInDisplay: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        _ = CGGetOnlineDisplayList(8, &ids, &count)
        for i in 0..<Int(count) where CGDisplayIsBuiltin(ids[i]) != 0 { return ids[i] }
        return CGMainDisplayID()
    }

    private func read() -> Float? {
        guard let fn = Self.symbols.get else { return nil }
        var value: Float = 0
        return fn(builtInDisplay, &value) == 0 ? value : nil
    }

    private func tick() {
        guard let v = read() else { return }
        if Self.lastSeen < 0 { Self.lastSeen = v; return }
        guard abs(v - Self.lastSeen) > 0.002 else { return }
        Self.lastSeen = v
        post(v)
    }

    private func post(_ value: Float) {
        guard Preferences.shared.brightnessHUDEnabled else { return }
        let hud = LevelHUD(kind: .brightness, level: Double(value))
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85), duration: 1.5, haptic: false)
    }
}
