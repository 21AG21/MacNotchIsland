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
            // The setter is `- (BOOL)enableAutoBrightness:(BOOL)arg1 forKeyboard:(unsigned long long)arg2`,
            // as the class-dumped `KeyboardBrightnessClient.h` that Lunar and mac-brightnessctl
            // build against declares it. There is no `setAutoBrightnessEnabled:forKeyboard:`, and
            // asking for one left automatic permanently unswitchable.
            return Bridge(client: client, keyboard: keyboard, read: read, write: write,
                          readAuto: CoreBrightness.method(client, "isAutoBrightnessEnabledForKeyboard:", as: ReadAuto.self),
                          writeAuto: CoreBrightness.method(client, "enableAutoBrightness:forKeyboard:", as: WriteAuto.self))
        }

        /// The keyboard this client names now, or nil for none — asked again on wake and when
        /// the displays change (`KeyboardLight.reprobe`). The keyboard itself and not only
        /// whether there is one: a client that has come to name a different keyboard drives
        /// that one, and a bridge kept for the old number set a light that was not there.
        func namedKeyboard() -> UInt64? {
            KeyboardLight.keyboard(from: Self.backlightIDs(client))
        }

        /// What the client says the backlit keyboards are, or nil when it cannot be asked — the
        /// method has gone. A client that has the method is asked, and whatever it answers is
        /// taken as its answer, nothing included: see `KeyboardLight.backlightIDs(answer:)`.
        private static func backlightIDs(_ client: NSObject) -> [UInt64]? {
            guard let copy = CoreBrightness.method(client, "copyKeyboardBacklightIDs", as: CopyIDs.self) else { return nil }
            let answer = copy.function(client, copy.selector).map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
            return KeyboardLight.backlightIDs(answer: answer)
        }
    }

    /// Found at launch, and looked for again on wake and whenever the displays change
    /// (`reprobe`): a client asked at login, or with the lid shut, can name no keyboard, and a
    /// bridge found once and never again left the disc off for the whole run.
    private var bridge: Bridge?
    private var viewers = 0
    private var timer: Timer?
    private var energyCancellable: AnyCancellable?
    /// A write the keyboard has not reported back yet; see `BrightnessControl.pending`.
    private var pending: (value: Double, until: TimeInterval)?
    /// The same for the automatic switch: CoreBrightness can take the switch a moment after it
    /// says yes, and the checkbox snapped back to what the read straight after it found.
    private var pendingAutomatic: (value: Bool, until: TimeInterval)?
    /// Held for as long as the app runs, like the service itself.
    private var observers: [NSObjectProtocol] = []
    /// The look that follows a look which found no keyboard where one had been working
    /// (`recheck`), `wakeSettle` later. One at a time: another look in the meantime that finds
    /// nothing leaves it as it is, and one that finds the keyboard calls it off. Main thread.
    private var secondLook: DispatchWorkItem?

    private init() {
        bridge = Bridge.load()
        isAvailable = bridge != nil
        refresh()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            // The daemon behind the client is not always answering the instant the Mac wakes.
            DispatchQueue.main.asyncAfter(deadline: .now() + KeyboardLight.wakeSettle) { self?.reprobe() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.reprobe()
        })
    }

    /// How long the daemon behind the client is given to answer: after a wake, and before a
    /// look that found no keyboard is taken as the keyboard's being gone (`recheck`).
    static let wakeSettle: TimeInterval = 2

    /// Looks for the backlight again: a lid opened, a keyboard's client that was not answering
    /// at login. A couple of calls into CoreBrightness, and only on the events that can change
    /// the answer. `isAvailable` is published only when it changes, which is what the service
    /// hub's subscription and the rail are waiting to hear. Main thread.
    ///
    /// A working bridge is only given up on a second look (`recheck`): a lid opening changes
    /// the screens before CoreBrightness has put the keyboard back, and one empty answer then
    /// took the disc away and handed the keys back to macOS until the next wake.
    private func reprobe(isTheSecondLook: Bool = false) {
        guard let bridge else {
            use(Bridge.load())
            return
        }
        var named = bridge.namedKeyboard()
        var replacement: Bridge?
        if let id = named, id != bridge.keyboard {
            // Built again for the keyboard named now; one that cannot be built named nothing.
            replacement = Bridge.load()
            named = replacement?.keyboard
        }
        switch Self.recheck(of: bridge.keyboard, named: named, isTheSecondLook: isTheSecondLook) {
        case .keep:
            callOffSecondLook()
        case .reload:
            IslandLog.display.notice("the keyboard backlight is another keyboard now")
            use(replacement)
        case .lookAgain:
            guard secondLook == nil else { return }
            IslandLog.display.notice("the keyboard backlight did not answer; looking again")
            let look = DispatchWorkItem { [weak self] in
                self?.secondLook = nil
                self?.reprobe(isTheSecondLook: true)
            }
            secondLook = look
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeSettle, execute: look)
        case .drop:
            use(nil)
        }
    }

    /// Puts `fresh` in the bridge's place, and says so when the backlight came or went. Main
    /// thread.
    private func use(_ fresh: Bridge?) {
        callOffSecondLook()
        bridge = fresh
        let available = fresh != nil
        let changed = isAvailable != available
        if changed {
            IslandLog.display.notice("keyboard backlight \(available ? "found" : "gone", privacy: .public)")
            isAvailable = available
        }
        if available {
            // A keyboard found, or a different one: its level, not the last one's.
            refresh()
            if changed, viewers > 0 { schedule() }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func callOffSecondLook() {
        secondLook?.cancel()
        secondLook = nil
    }

    // MARK: - Pure rules

    /// What a look at a working bridge does with it.
    enum Recheck: Equatable {
        /// The same keyboard answered: nothing changes.
        case keep
        /// A different keyboard answered: the bridge drives that one from now on.
        case reload
        /// No keyboard answered, and this was the first look to say so: the bridge is kept and
        /// looked at again once the daemon has had `wakeSettle` to come back.
        case lookAgain
        /// No keyboard on the second look either: the backlight is gone.
        case drop
    }

    /// A working bridge is given up only when two looks in a row, `wakeSettle` apart, find no
    /// keyboard. One empty answer used to be enough, and a lid opening asks at just the moment
    /// CoreBrightness may not have put the keyboard back yet. A keyboard with a new number is
    /// driven by that number. Pure, so it is tested.
    static func recheck(of keyboard: UInt64, named: UInt64?, isTheSecondLook: Bool) -> Recheck {
        guard let named else { return isTheSecondLook ? .drop : .lookAgain }
        return named == keyboard ? .keep : .reload
    }

    /// The keyboard to drive: the first the client names. A client that cannot be asked — the
    /// method has gone — gets the first keyboard's number, 1, which is the built-in one on every
    /// Mac that has one. A client that was asked and named none is a Mac with no backlit
    /// keyboard, and gets no slider for one.
    static func keyboard(from ids: [UInt64]?) -> UInt64? {
        guard let ids else { return 1 }
        return ids.first
    }

    /// The keyboards a client that was asked named. An answer of nothing — or of something that
    /// is not a list of numbers — is no backlit keyboard, never "could not ask": only a missing
    /// method is that, and it never gets this far. Mistaking the one for the other gave a Mac
    /// with no backlight a slider and a display for a light it does not have.
    static func backlightIDs(answer: Any?) -> [UInt64] {
        (answer as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    /// Whether a reading of the automatic switch may replace what is shown, or is older than
    /// what the user just set: the same hold the level has. Pure, so it is tested.
    static func acceptsAutomatic(_ reading: Bool, holding: (value: Bool, until: TimeInterval)?,
                                 now: TimeInterval) -> Bool {
        guard let holding else { return true }
        return now >= holding.until || holding.value == reading
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
        pendingAutomatic = (on, LocalWrite.now() + Self.writeSettle)
        if isAutomatic != on { isAutomatic = on }
        if !writeAuto.function(bridge.client, writeAuto.selector, on, bridge.keyboard) {
            // Refused: say so, and show the truth again at once rather than after the hold.
            IslandLog.display.error("the keyboard backlight refused automatic adjustment \(on ? "on" : "off", privacy: .public)")
            pendingAutomatic = nil
        }
        refresh()
    }

    /// Whether automatic adjustment can be switched at all on this Mac.
    var canSetAutomatic: Bool { bridge?.writeAuto != nil }

    func refresh() {
        guard let bridge, let value = read() else { return }
        if let readAuto = bridge.readAuto {
            let automatic = readAuto.function(bridge.client, readAuto.selector, bridge.keyboard)
            if Self.acceptsAutomatic(automatic, holding: pendingAutomatic, now: LocalWrite.now()) {
                pendingAutomatic = nil
                if isAutomatic != automatic { isAutomatic = automatic }
            }
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
