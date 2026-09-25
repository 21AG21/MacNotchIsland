import AppKit
import Combine

/// Brightness HUD. There is no public change notification, so the built-in display's
/// brightness is sampled through DisplayServices (cheap call) — every two seconds while the
/// island answers the brightness keys, which announce themselves, and four times a second
/// while it does not (`pollInterval`). The same private symbols also let the media-key
/// interceptor set the brightness when it replaces the system bezel.
final class BrightnessMonitor {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// DisplayServices is resolved once for the whole process: the monitor started by the
    /// service hub and the media-key interceptor both go through it.
    private static let symbols: (get: GetBrightnessFn?, set: SetBrightnessFn?) = BrightnessMonitor.loadSymbols()

    private static func loadSymbols() -> (get: GetBrightnessFn?, set: SetBrightnessFn?) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else {
            IslandLog.display.error("DisplayServices is unavailable; the brightness display is off")
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
            IslandLog.display.error("DisplayServices brightness symbols are missing; get \(get != nil, privacy: .public), set \(set != nil, privacy: .public)")
        }
        return (get, set)
    }

    /// Last value reported to the island. Shared so a value we set ourselves is not
    /// announced twice (once by the setter, once by the poll). Main thread only.
    private static var lastSeen: Float = -1
    /// How many monitors are sampling, see `lastSample`. Main thread only.
    private static var sampling = 0

    /// The panel's brightness as last read here, 0...1 — by the poll, or by the key tap as it
    /// set it — or nil while no monitor is running, when nothing keeps it current. For the
    /// rail's slider, which can follow this rather than read the display on a timer of its
    /// own. Main thread only.
    static var lastSample: Float? { sampling > 0 && lastSeen >= 0 ? lastSeen : nil }

    private var timer: Timer?
    private var running = false

    private var cancellables = Set<AnyCancellable>()

    /// How often the panel is read. Pure, so it is tested.
    ///
    /// While the island answers the brightness keys (`answersKeys`), every press is already
    /// announced the moment it is applied (`MediaKeyInterceptor.adjustBrightness`, through
    /// `notifyChange`), and the poll has only Control Centre's slider and the light sensor
    /// left to catch — neither of which needs catching four times a second. It polled at 4 Hz
    /// anyway, on the main thread, for as long as the app ran. While the island does not
    /// answer them, macOS takes the keys and says nothing, and looking often is the only way
    /// anything here follows them.
    static func pollInterval(answersKeys: Bool, multiplier: Double) -> TimeInterval {
        (answersKeys ? 2 : 0.25) * max(1, multiplier)
    }

    func start() {
        guard !running, Self.symbols.get != nil else { return }
        running = true
        Self.sampling += 1
        Self.lastSeen = read() ?? -1
        scheduleTimer()
        EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
            .store(in: &cancellables)
        // The tap coming up or going down changes who announces a key. Hopped through the main
        // queue: `@Published` announces a value before it is stored, and the rule reads it.
        // What the tap can answer changes with no announcement at all, and is picked up at
        // the next reading instead (`tick`).
        SystemHUDReplacement.shared.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
            .store(in: &cancellables)
    }

    /// Rebuilds the timer when the interval it should run at has changed, and only then: a
    /// rebuild pushes the next reading back by a whole interval.
    private func scheduleTimer() {
        guard running else { return }
        let interval = Self.pollInterval(answersKeys: SystemHUDReplacement.shared.answersBrightness,
                                         multiplier: EnergyPolicy.shared.pollingMultiplier)
        if let timer, abs(timer.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = interval * 0.2
    }

    func stop() {
        guard running else { return }
        running = false
        Self.sampling = max(0, Self.sampling - 1)
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
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
            IslandLog.display.error("could not set brightness (status \(status, privacy: .public))")
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
        Self.drivenDisplay(in: Self.onlineDisplays(), isBuiltIn: { CGDisplayIsBuiltin($0) != 0 }, main: CGMainDisplayID())
    }

    /// The built-in panel, whichever of the screens on the desk it is: the window server hands
    /// its list back in no order worth relying on. Nothing when there is none, which is a Mac
    /// with only an external display attached and no brightness of its own to set.
    ///
    /// Kept apart from the window server's own answer so the rule can be checked without a Mac
    /// to check it on.
    static func builtInDisplay(in ids: [CGDirectDisplayID], isBuiltIn: (CGDirectDisplayID) -> Bool) -> CGDirectDisplayID? {
        ids.first(where: isBuiltIn)
    }

    /// The display this monitor reads and writes, and so the one the rail's slider drives: the
    /// built-in panel, or with none online — the lid shut on an external display — the main
    /// display, where a write is free to fail and one that takes it moves that display.
    ///
    /// The Display popover asks this same rule which display is the rail's
    /// (`DisplayControl.sliderDisplays`), so it can never give that display a second slider of
    /// its own.
    static func drivenDisplay(in ids: [CGDirectDisplayID], isBuiltIn: (CGDirectDisplayID) -> Bool,
                              main: CGDirectDisplayID) -> CGDirectDisplayID {
        builtInDisplay(in: ids, isBuiltIn: isBuiltIn) ?? main
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        _ = CGGetOnlineDisplayList(8, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private func read() -> Float? {
        guard let fn = Self.symbols.get else { return nil }
        var value: Float = 0
        return fn(builtInDisplay, &value) == 0 ? value : nil
    }

    private func tick() {
        scheduleTimer()
        guard let v = read() else { return }
        if Self.lastSeen < 0 { Self.lastSeen = v; return }
        let previous = Self.lastSeen
        // Every reading is taken in, announced or not, so a slow drift is absorbed a little at
        // a time and never adds up to something that looks like a step. See `isDeliberate`.
        Self.lastSeen = v
        guard Self.isDeliberate(from: previous, to: v) else { return }
        post(v)
    }

    /// Whether the move between two readings is somebody's hand rather than the light sensor.
    ///
    /// Anything over 0.002 used to raise the overlay, and auto-brightness moves the panel by
    /// more than that all day: walk past a window and the island announced it, over and over,
    /// with nobody touching anything. The line is the smallest step anybody takes by hand —
    /// Shift-Option's quarter notch, 1/64 — less a little for a figure read back a hair under
    /// what was written. It rests on how macOS reports an ambient change: as a ramp, a sliver
    /// at each reading, where a key arrives as a step. A ramp steep enough to cover a quarter
    /// notch between two readings still shows, and a slider dragged slowly enough does not.
    static func isDeliberate(from previous: Float, to current: Float) -> Bool {
        abs(current - previous) >= MediaKeyInterceptor.fineStep * 0.9
    }

    private func post(_ value: Float) {
        // As with volume: silent unless the island is the one answering the keys.
        // And not for a change the island's own slider just made: a banner covering the
        // control you are holding is the same duplicated feedback in miniature.
        guard Preferences.shared.brightnessHUDEnabled, SystemHUDReplacement.shared.answersBrightness,
              !BrightnessControl.wroteRecently() else { return }
        let hud = LevelHUD(kind: .brightness, level: Double(value))
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85), duration: 1.5, haptic: false)
    }
}
