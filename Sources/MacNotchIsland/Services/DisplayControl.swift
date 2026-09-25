import AppKit
import Combine
import CoreGraphics
import ObjectiveC

/// What Control Centre's Display module holds, for the rail's Display popover: a brightness
/// slider for every display that will take one, and the switches for Night Shift and True Tone.
/// Dark Mode is in the same popover but is `SystemToggles`' — it already had a home.
///
/// Every piece of this is private API and none of it is trusted to exist. Brightness is
/// DisplayServices' two calls, which the brightness display already relies on for the built-in
/// panel; Night Shift is CoreBrightness's `CBBlueLightClient` and True Tone its
/// `CBTrueToneClient`. Each is looked up by name, each method is asked for before it is called,
/// and a control whose calls are missing is not drawn at all.
///
/// The built-in panel is not driven from here. `BrightnessControl` already reads and writes it
/// for the rail's own slider, and two pollers writing one display would argue with each other;
/// its slider in the popover is that one.
///
/// Readings are taken off the main thread — a display on the far end of a cable answers in its
/// own time — when the popover opens and every two seconds while it is open, slower on battery.
final class DisplayControl: ObservableObject {
    static let shared = DisplayControl()

    /// A display with a brightness slider.
    struct Screen: Identifiable, Equatable {
        let id: CGDirectDisplayID
        var name: String
        /// The built-in panel, whose level is `BrightnessControl`'s rather than read here.
        var isBuiltIn: Bool
        var level: Double
    }

    /// The built-in panel first, when it answers, then every other display that does.
    @Published private(set) var screens: [Screen] = []
    /// A first pass has come back, so an empty `screens` means no display answered rather than
    /// that none has been asked yet.
    @Published private(set) var hasRead = false
    /// Night Shift can be switched on this Mac.
    @Published private(set) var hasNightShift = false
    @Published private(set) var nightShiftOn = false
    /// Night Shift's warmth, 0...1. Nil when the strength calls are missing and there is no
    /// warmth slider to show.
    @Published private(set) var nightShiftStrength: Double?
    /// True Tone is supported by a display attached to this Mac.
    @Published private(set) var hasTrueTone = false
    /// Supported, but not available at the moment — the display that has it is asleep, or
    /// something else has it turned off. The switch is shown and cannot be moved.
    @Published private(set) var trueToneAvailable = false
    @Published private(set) var trueToneOn = false

    static let pollInterval: TimeInterval = 2
    /// How long a value the popover wrote is shown before a reading that disagrees is believed.
    static let writeSettle: TimeInterval = 1.5

    // MARK: - DisplayServices

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let brightnessCalls: (get: GetBrightness, set: SetBrightness)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else {
            IslandLog.display.notice("DisplayServices brightness calls are missing; no display gets a slider")
            return nil
        }
        return (get: unsafeBitCast(get, to: GetBrightness.self), set: unsafeBitCast(set, to: SetBrightness.self))
    }()

    // MARK: - CoreBrightness

    private typealias ClassFlag = @convention(c) (AnyClass, Selector) -> Bool
    private typealias Flag = @convention(c) (AnyObject, Selector) -> Bool
    private typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias ReadStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias ReadStrength = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
    private typealias WriteStrength = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool

    /// Room for `CBBlueLightClient`'s status structure, which is well under this. It starts
    /// `BOOL active; BOOL enabled; …`, and the second byte is the switch.
    static let statusSize = 64

    private struct NightShift {
        let client: NSObject
        let status: CoreBrightness.Bound<ReadStatus>
        let setEnabled: CoreBrightness.Bound<SetFlag>
        let strength: CoreBrightness.Bound<ReadStrength>?
        let setStrength: CoreBrightness.Bound<WriteStrength>?

        static func load() -> NightShift? {
            guard CoreBrightness.isLoaded, let blueLight = NSClassFromString("CBBlueLightClient") else { return nil }
            // The class says whether this Mac can do it at all, where it has the question.
            let supportsName = NSSelectorFromString("supportsBlueLightReduction")
            if let method = class_getClassMethod(blueLight, supportsName) {
                let supports = unsafeBitCast(method_getImplementation(method), to: ClassFlag.self)
                guard supports(blueLight, supportsName) else { return nil }
            }
            guard let client = CoreBrightness.instance(of: "CBBlueLightClient"),
                  let status = CoreBrightness.method(client, "getBlueLightStatus:", as: ReadStatus.self),
                  let setEnabled = CoreBrightness.method(client, "setEnabled:", as: SetFlag.self) else { return nil }
            return NightShift(client: client, status: status, setEnabled: setEnabled,
                              strength: CoreBrightness.method(client, "getStrength:", as: ReadStrength.self),
                              setStrength: CoreBrightness.method(client, "setStrength:commit:", as: WriteStrength.self))
        }

        /// The switch, or nil when the status would not be read.
        func isOn() -> Bool? {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: DisplayControl.statusSize, alignment: 8)
            defer { buffer.deallocate() }
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: DisplayControl.statusSize)
            guard status.function(client, status.selector, buffer) else { return nil }
            let bytes = Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self),
                                                  count: DisplayControl.statusSize))
            return DisplayControl.nightShiftIsOn(status: bytes)
        }

        func warmth() -> Double? {
            guard let strength else { return nil }
            var value: Float = 0
            guard strength.function(client, strength.selector, &value), value.isFinite else { return nil }
            return min(1, max(0, Double(value)))
        }
    }

    private struct TrueTone {
        let client: NSObject
        let supported: CoreBrightness.Bound<Flag>
        let available: CoreBrightness.Bound<Flag>?
        let enabled: CoreBrightness.Bound<Flag>
        let setEnabled: CoreBrightness.Bound<SetFlag>

        static func load() -> TrueTone? {
            guard let client = CoreBrightness.instance(of: "CBTrueToneClient"),
                  let supported = CoreBrightness.method(client, "supported", as: Flag.self),
                  let enabled = CoreBrightness.method(client, "enabled", as: Flag.self),
                  let setEnabled = CoreBrightness.method(client, "setEnabled:", as: SetFlag.self) else { return nil }
            return TrueTone(client: client, supported: supported,
                            available: CoreBrightness.method(client, "available", as: Flag.self),
                            enabled: enabled, setEnabled: setEnabled)
        }
    }

    // MARK: - State

    /// Found on first use, on the queue below, and kept.
    private var nightShift: NightShift?
    private var trueTone: TrueTone?
    private var bridgesLoaded = false

    /// Every private call is made here, one at a time.
    private let queue = DispatchQueue(label: "com.macnotchisland.display", qos: .utility)
    private var reading = false
    private var viewers = 0
    private var timer: Timer?
    private var energyCancellable: AnyCancellable?
    /// Values the popover wrote that the system has not reported back yet, by key.
    private var holds: [String: (value: Double, until: TimeInterval)] = [:]

    private init() {}

    // MARK: - Pure rules

    /// Which displays get a slider, in the order they are shown: the built-in panel first when
    /// its own brightness service answers, then every other display whose brightness read
    /// comes back with a status of zero. A display that answers anything else — most monitors
    /// on the far end of a cable — has no slider rather than one that does nothing.
    static func sliderDisplays(online: [CGDirectDisplayID],
                               isBuiltIn: (CGDirectDisplayID) -> Bool,
                               builtInAnswers: Bool,
                               status: (CGDirectDisplayID) -> Int32?) -> [CGDirectDisplayID] {
        var seen: Set<CGDirectDisplayID> = []
        var builtIn: [CGDirectDisplayID] = []
        var others: [CGDirectDisplayID] = []
        for id in online where seen.insert(id).inserted {
            if isBuiltIn(id) {
                // One built-in panel, driven by `BrightnessControl`.
                if builtInAnswers, builtIn.isEmpty { builtIn.append(id) }
            } else if status(id) == 0 {
                others.append(id)
            }
        }
        return builtIn + others
    }

    /// Night Shift's switch, read out of the status structure: the second byte. Nil when the
    /// buffer is too short to hold it.
    static func nightShiftIsOn(status: [UInt8]) -> Bool? {
        status.count > 1 ? status[1] != 0 : nil
    }

    // MARK: - Viewers

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        refresh()
        schedule()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.viewers > 0 else { return }
                self.schedule()
            }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        energyCancellable = nil
    }

    private func schedule() {
        timer?.invalidate()
        let interval = Self.pollInterval * EnergyPolicy.shared.pollingMultiplier
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Reading

    private struct Snapshot {
        var screens: [Screen] = []
        var nightShift: (on: Bool, warmth: Double?)?
        var trueTone: (available: Bool, on: Bool)?
    }

    /// One pass over everything the popover shows. A pass already in the air is the answer to
    /// this one too.
    func refresh() {
        guard !reading else { return }
        reading = true
        // Read here, on the main thread, and carried in: the screens' names are AppKit's, and
        // whether the built-in panel answers is the brightness service's own reading.
        let names = Self.screenNames()
        let builtInAnswers = BrightnessControl.shared.isAvailable
        let builtInLevel = BrightnessControl.shared.level
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.take(names: names, builtInAnswers: builtInAnswers, builtInLevel: builtInLevel)
            DispatchQueue.main.async {
                self.reading = false
                self.apply(snapshot)
            }
        }
    }

    /// On the queue.
    private func take(names: [CGDirectDisplayID: String], builtInAnswers: Bool, builtInLevel: Double) -> Snapshot {
        if !bridgesLoaded {
            bridgesLoaded = true
            nightShift = NightShift.load()
            trueTone = TrueTone.load()
        }
        var snapshot = Snapshot()
        var levels: [CGDirectDisplayID: Double] = [:]
        let online = Self.onlineDisplays()
        let ids = Self.sliderDisplays(online: online, isBuiltIn: { CGDisplayIsBuiltin($0) != 0 },
                                      builtInAnswers: builtInAnswers) { id in
            guard let calls = Self.brightnessCalls else { return nil }
            var value: Float = 0
            let status = calls.get(id, &value)
            if status == 0 { levels[id] = min(1, max(0, Double(value))) }
            return status
        }
        snapshot.screens = ids.map { id in
            let builtIn = CGDisplayIsBuiltin(id) != 0
            return Screen(id: id, name: names[id] ?? (builtIn ? "Built-in Display" : "Display"),
                          isBuiltIn: builtIn, level: builtIn ? builtInLevel : (levels[id] ?? 0))
        }
        if let nightShift, let on = nightShift.isOn() {
            snapshot.nightShift = (on: on, warmth: nightShift.warmth())
        }
        if let trueTone, trueTone.supported.function(trueTone.client, trueTone.supported.selector) {
            let available = trueTone.available.map { $0.function(trueTone.client, $0.selector) } ?? true
            snapshot.trueTone = (available: available,
                                 on: trueTone.enabled.function(trueTone.client, trueTone.enabled.selector))
        }
        return snapshot
    }

    /// Main thread.
    private func apply(_ snapshot: Snapshot) {
        if !hasRead { hasRead = true }
        let screens = snapshot.screens.map { screen -> Screen in
            var screen = screen
            // A slider under the hand keeps what the hand set until the display agrees.
            if !screen.isBuiltIn, let shown = self.screens.first(where: { $0.id == screen.id }),
               !accepts("display-\(screen.id)", screen.level) {
                screen.level = shown.level
            }
            return screen
        }
        if screens != self.screens { self.screens = screens }

        let hasNightShift = snapshot.nightShift != nil
        if self.hasNightShift != hasNightShift { self.hasNightShift = hasNightShift }
        if let night = snapshot.nightShift {
            if accepts("nightShift", night.on ? 1 : 0), nightShiftOn != night.on { nightShiftOn = night.on }
            if let warmth = night.warmth {
                if accepts("warmth", warmth), nightShiftStrength.map({ abs($0 - warmth) > 0.001 }) ?? true {
                    nightShiftStrength = warmth
                }
            } else if nightShiftStrength != nil {
                nightShiftStrength = nil
            }
        }

        let hasTrueTone = snapshot.trueTone != nil
        if self.hasTrueTone != hasTrueTone { self.hasTrueTone = hasTrueTone }
        if let tone = snapshot.trueTone {
            if trueToneAvailable != tone.available { trueToneAvailable = tone.available }
            if accepts("trueTone", tone.on ? 1 : 0), trueToneOn != tone.on { trueToneOn = tone.on }
        }
    }

    /// Whether a reading may replace what is shown, or is older than what the user just set.
    private func accepts(_ key: String, _ value: Double) -> Bool {
        guard let hold = holds[key] else { return true }
        guard LocalWrite.now() >= hold.until || abs(hold.value - value) < 0.02 else { return false }
        holds[key] = nil
        return true
    }

    private func hold(_ key: String, _ value: Double) {
        holds[key] = (value, LocalWrite.now() + Self.writeSettle)
    }

    // MARK: - Writing

    /// Sets one display's brightness. The built-in panel goes through `BrightnessControl`, which
    /// owns it.
    func setBrightness(_ value: Double, display: CGDirectDisplayID) {
        let level = min(1, max(0, value))
        guard let index = screens.firstIndex(where: { $0.id == display }) else { return }
        if screens[index].isBuiltIn {
            BrightnessControl.shared.set(level)
            return
        }
        hold("display-\(display)", level)
        screens[index].level = level
        queue.async {
            guard let calls = Self.brightnessCalls else { return }
            let status = calls.set(display, Float(level))
            if status != 0 {
                IslandLog.display.error("display \(display, privacy: .public) refused a brightness (status \(status, privacy: .public))")
            }
        }
    }

    func setNightShift(_ on: Bool) {
        guard hasNightShift else { return }
        hold("nightShift", on ? 1 : 0)
        if nightShiftOn != on { nightShiftOn = on }
        queue.async { [weak self] in
            guard let night = self?.nightShift else { return }
            _ = night.setEnabled.function(night.client, night.setEnabled.selector, on)
        }
    }

    /// What macOS's own Night Shift settings call "Turn on until tomorrow". Switching Night Shift
    /// on by hand is exactly that there: it stays on until the next morning's schedule turns it
    /// off, whatever the schedule would otherwise have done tonight.
    func turnOnNightShiftUntilTomorrow() {
        setNightShift(true)
    }

    /// Night Shift's warmth, 0...1.
    func setNightShiftStrength(_ value: Double) {
        guard nightShiftStrength != nil else { return }
        let strength = min(1, max(0, value))
        hold("warmth", strength)
        nightShiftStrength = strength
        queue.async { [weak self] in
            guard let night = self?.nightShift, let write = night.setStrength else { return }
            _ = write.function(night.client, write.selector, Float(strength), true)
        }
    }

    func setTrueTone(_ on: Bool) {
        guard hasTrueTone, trueToneAvailable else { return }
        hold("trueTone", on ? 1 : 0)
        if trueToneOn != on { trueToneOn = on }
        queue.async { [weak self] in
            guard let tone = self?.trueTone else { return }
            _ = tone.setEnabled.function(tone.client, tone.setEnabled.selector, on)
        }
    }

    // MARK: - Displays

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        let capacity: UInt32 = 16
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(capacity, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Each screen's own name, the one System Settings shows. Main thread.
    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return names
    }
}
