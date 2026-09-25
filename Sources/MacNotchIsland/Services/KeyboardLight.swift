import AppKit
import Combine
import ObjectiveC

/// CoreBrightness: the private framework behind Control Centre's keyboard brightness, Night Shift
/// and True Tone. None of it is public API, so none of it is trusted to exist. The framework is
/// opened once by path, every class is found by name and every method is asked for before it is
/// called — a macOS that has moved or renamed any part of it leaves the control that needed it
/// hidden, never a crash and never a switch that does nothing.
///
/// The methods take floats, 64-bit integers and BOOLs, which `perform(_:)` cannot pass. So each
/// one is called the way the runtime itself would: its implementation is looked up on the class
/// and cast to the C function it really is, receiver and selector first.
enum CoreBrightness {
    static let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    /// Whether the framework is in the process. Opened once: a second `dlopen` of an image that is
    /// already loaded is only a reference count, but there is no reason to ask twice.
    static let isLoaded: Bool = {
        guard dlopen(path, RTLD_NOW) != nil else {
            IslandLog.display.notice("CoreBrightness is not there; the keyboard, Night Shift and True Tone controls stay hidden")
            return false
        }
        return true
    }()

    /// An instance of the named class, allocated and initialised through the runtime, or nothing
    /// when the class is not there.
    static func instance(of className: String) -> NSObject? {
        guard isLoaded, let type = NSClassFromString(className) as? NSObject.Type else { return nil }
        return type.init()
    }

    /// A method and the function behind it.
    struct Bound<Function> {
        let selector: Selector
        let function: Function
    }

    /// The implementation of `name` on `object`, cast to `Function` — which must be the
    /// `@convention(c)` type the method really has, with the receiver and the selector as its
    /// first two arguments. Nothing when the object does not answer to it.
    static func method<Function>(_ object: NSObject, _ name: String, as _: Function.Type) -> Bound<Function>? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector) else { return nil }
        return Bound(selector: selector, function: unsafeBitCast(method_getImplementation(method), to: Function.self))
    }
}

/// The keyboard backlight, through CoreBrightness's `KeyboardBrightnessClient` — the same client
/// Control Centre's Keyboard Brightness module talks to. There is no public API for the backlight
/// at all, which is why the island used to leave its keys to macOS.
///
/// The level is published so the rail's slider follows the keys, Control Centre and the ambient
/// light sensor. There is no notification for it, so it is polled — once a second, only while
/// something that shows it is on screen, and slower on battery.
final class KeyboardLight: ObservableObject {
    static let shared = KeyboardLight()

    /// There is a backlight to set: the client is there, it answers the calls the island makes,
    /// and it names a keyboard. False on a Mac with no backlit keyboard, and on a macOS that has
    /// changed the client, where every control for it stays hidden and its keys stay macOS's.
    @Published private(set) var isAvailable = false
    /// 0...1.
    @Published private(set) var level: Double = 0
    /// The backlight follows the room's light by itself.
    @Published private(set) var isAutomatic = false

    /// One notch of the keyboard's own bar, the same sixteen the display has.
    static let coarseStep: Double = 1.0 / 16.0
    /// The Shift+Option quarter notch.
    static let fineStep: Double = 1.0 / 64.0
    static let pollInterval: TimeInterval = 1
    /// How long a level the island wrote is shown before a reading that disagrees is believed.
    static let writeSettle: TimeInterval = 1

    private typealias ReadLevel = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias WriteLevel = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias ReadAuto = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias WriteAuto = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    /// `copy…`, so the array comes back retained and is taken that way.
    private typealias CopyIDs = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?

    /// The client and the four calls, found once.
    private struct Bridge {
        let client: NSObject
        let keyboard: UInt64
        let read: CoreBrightness.Bound<ReadLevel>
        let write: CoreBrightness.Bound<WriteLevel>
        let readAuto: CoreBrightness.Bound<ReadAuto>?
        let writeAuto: CoreBrightness.Bound<WriteAuto>?

        /// Reading and setting the level are the whole of it; without both there is no control.
        /// Automatic is a nicety and may be missing on its own.
        static func load() -> Bridge? {
            guard let client = CoreBrightness.instance(of: "KeyboardBrightnessClient"),
                  let read = CoreBrightness.method(client, "brightnessForKeyboard:", as: ReadLevel.self),
                  let write = CoreBrightness.method(client, "setBrightness:forKeyboard:", as: WriteLevel.self) else {
                return nil
            }
            guard let keyboard = KeyboardLight.keyboard(from: backlightIDs(client)) else {
                IslandLog.display.notice("the keyboard brightness client names no backlit keyboard")
                return nil
            }
            return Bridge(client: client, keyboard: keyboard, read: read, write: write,
                          readAuto: CoreBrightness.method(client, "isAutoBrightnessEnabledForKeyboard:", as: ReadAuto.self),
                          writeAuto: CoreBrightness.method(client, "setAutoBrightnessEnabled:forKeyboard:", as: WriteAuto.self))
        }

        /// What the client says the backlit keyboards are, or nil when it cannot be asked.
        private static func backlightIDs(_ client: NSObject) -> [UInt64]? {
            guard let copy = CoreBrightness.method(client, "copyKeyboardBacklightIDs", as: CopyIDs.self),
                  let raw = copy.function(client, copy.selector) else { return nil }
            let list = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
            return (list as? [NSNumber])?.map(\.uint64Value)
        }
    }

    private let bridge: Bridge?
    private var viewers = 0
    private var timer: Timer?
    private var energyCancellable: AnyCancellable?
    /// A write the keyboard has not reported back yet; see `BrightnessControl.pending`.
    private var pending: (value: Double, until: TimeInterval)?

    private init() {
        bridge = Bridge.load()
        isAvailable = bridge != nil
        refresh()
    }

    // MARK: - Pure rules

    /// The keyboard to drive: the first the client names. A client that cannot be asked — the
    /// method has gone — gets the first keyboard's number, 1, which is the built-in one on every
    /// Mac that has one. A client that was asked and named none is a Mac with no backlit
    /// keyboard, and gets no slider for one.
    static func keyboard(from ids: [UInt64]?) -> UInt64? {
        guard let ids else { return 1 }
        return ids.first
    }

    /// Held to 0...1, with anything that is not a number read as off.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// The next notch on the same sixteen-step grid the display's keys use, a quarter notch with
    /// Shift and Option held. A press always moves, even from between two notches, and stops at
    /// either end.
    static func stepped(from current: Double, up: Bool, fine: Bool) -> Double {
        let step = fine ? fineStep : coarseStep
        return Double(MediaKeyInterceptor.stepped(from: Float(clamped(current)), delta: up ? 1 : -1, step: Float(step)))
    }

    // MARK: - Reading and writing

    /// What the keyboard says it is set to right now, or nil when there is nothing to ask.
    func read() -> Double? {
        guard let bridge else { return nil }
        let value = bridge.read.function(bridge.client, bridge.read.selector, bridge.keyboard)
        guard value.isFinite, value >= 0 else { return nil }
        return Self.clamped(Double(value))
    }

    /// When the island last set the backlight itself. See `LocalWrite`.
    private(set) static var lastLocalWrite = LocalWrite.never

    static func wroteRecently(now: TimeInterval = LocalWrite.now()) -> Bool {
        LocalWrite.isRecent(lastLocalWrite, now: now)
    }

    func set(_ value: Double) {
        guard let bridge else { return }
        let target = Self.clamped(value)
        Self.lastLocalWrite = LocalWrite.now()
        pending = (target, LocalWrite.now() + Self.writeSettle)
        if level != target { level = target }
        if !bridge.write.function(bridge.client, bridge.write.selector, Float(target), bridge.keyboard) {
            IslandLog.display.error("the keyboard backlight refused a level")
        }
    }

    func setAutomatic(_ on: Bool) {
        guard let bridge, let writeAuto = bridge.writeAuto else { return }
        if isAutomatic != on { isAutomatic = on }
        _ = writeAuto.function(bridge.client, writeAuto.selector, on, bridge.keyboard)
        refresh()
    }

    /// Whether automatic adjustment can be switched at all on this Mac.
    var canSetAutomatic: Bool { bridge?.writeAuto != nil }

    func refresh() {
        guard let bridge, let value = read() else { return }
        if let readAuto = bridge.readAuto {
            let automatic = readAuto.function(bridge.client, readAuto.selector, bridge.keyboard)
            if isAutomatic != automatic { isAutomatic = automatic }
        }
        if let pending {
            guard LocalWrite.now() >= pending.until || abs(pending.value - value) < 0.02 else { return }
            self.pending = nil
        }
        if abs(level - value) > 0.001 { level = value }
    }

    // MARK: - Viewers

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        refresh()
        schedule()
        // Slower on battery and in Low Power Mode, the way every other poller here backs off.
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
        guard isAvailable else { return }
        let interval = Self.pollInterval * EnergyPolicy.shared.pollingMultiplier
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - The island's display

    /// Raises the island's level display for the backlight, unless its switch is off. For the
    /// keys and a Control-scroll on the island, which macOS draws nothing for once the island
    /// has them; never for the rail's own slider, which is its own feedback.
    static func showHUD(level: Double) {
        guard Preferences.shared.keyboardLightHUDEnabled else { return }
        let hud = LevelHUD(kind: .keyboard, level: clamped(level))
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85),
                                        duration: 1.5, haptic: false)
    }
}
