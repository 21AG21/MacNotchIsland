import AppKit
import Combine

/// Brightness HUD. There is no public change notification, so the built-in display's
/// brightness is sampled through DisplayServices (cheap call) every two seconds while the
/// island answers the brightness keys, which announce themselves, and not at all while it does
/// not (`look`). The same private symbols also let the media-key interceptor set the brightness
/// when it replaces the system bezel.
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

    /// Last value reported to the island, or -1 for none to compare with. Shared so a value we
    /// set ourselves is not announced twice (once by the setter, once by the poll). Main thread
    /// only.
    private static var lastSeen: Float = -1

    private var timer: Timer?
    private var running = false
    /// Whether the island was answering the brightness keys at the last tick. Main thread.
    private var wasAnswering = false

    private var cancellables = Set<AnyCancellable>()

    /// How often the timer comes round: every two seconds, slower for the energy policy. Pure,
    /// so it is tested.
    ///
    /// While the island answers the brightness keys, every press is already announced the
    /// moment it is applied (`MediaKeyInterceptor.adjustBrightness`, through `notifyChange`),
    /// and the poll has only Control Centre's slider and the light sensor left to catch —
    /// neither of which needs catching four times a second. While it does not, nothing here may
    /// be announced at all (`post`), and the timer is there only to notice the island starting
    /// to answer them: what the tap can answer changes without a word. It ran at four a second
    /// exactly then, on the main thread, to keep a remembered level current that nothing read;
    /// the level is taken afresh when the island starts answering instead (`look`).
    static func pollInterval(multiplier: Double) -> TimeInterval {
        2 * max(1, multiplier)
    }

    /// What a tick does with the panel.
    enum Look: Equatable {
        /// macOS has the keys and draws its own bezel for them: the panel is not read.
        case skip
        /// A reading to remember, not to announce: the island has only just started answering
        /// the keys, and whatever the level did before that was macOS's to announce — which it
        /// did — or there is no earlier reading to compare with.
        case baseline
        /// A reading to compare with the last, and announce if it is a step (`isDeliberate`).
        case compare
    }

    /// Pure, so it is tested.
    static func look(answering: Bool, wasAnswering: Bool, hasBaseline: Bool) -> Look {
        guard answering else { return .skip }
        return wasAnswering && hasBaseline ? .compare : .baseline
    }

    func start() {
        guard !running, Self.symbols.get != nil else { return }
        running = true
        resync()
        scheduleTimer()
        EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
            .store(in: &cancellables)
        // The tap coming up or going down changes who announces a key, and the level to compare
        // with is taken again then rather than at the next tick. Hopped through the main queue:
        // `@Published` announces a value before it is stored, and `answersBrightness` reads it.
        // What the tap can answer changes with no announcement at all, and is picked up at the
        // next tick instead (`look`).
        SystemHUDReplacement.shared.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resync() }
            .store(in: &cancellables)
    }

    /// Takes the level to compare with afresh, for whoever answers the keys now. Nothing to
    /// compare with while macOS has them: `look` reads nothing then, and the level it would
    /// remember is one macOS has long since moved past. Main thread.
    private func resync() {
        guard running else { return }
        wasAnswering = SystemHUDReplacement.shared.answersBrightness
        Self.lastSeen = wasAnswering ? (read() ?? -1) : -1
    }

    /// Rebuilds the timer when the interval it should run at has changed, and only then: a
    /// rebuild pushes the next reading back by a whole interval.
    private func scheduleTimer() {
        guard running else { return }
        let interval = Self.pollInterval(multiplier: EnergyPolicy.shared.pollingMultiplier)
        if let timer, abs(timer.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = interval * 0.2
    }

    func stop() {
        guard running else { return }
        running = false
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
        let answering = SystemHUDReplacement.shared.answersBrightness
        let next = Self.look(answering: answering, wasAnswering: wasAnswering, hasBaseline: Self.lastSeen >= 0)
        wasAnswering = answering
        guard next != .skip, let v = read() else { return }
        guard next == .compare else {
            Self.lastSeen = v
            return
        }
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
