import AppKit
// Imported for what it loads, not for anything it declares: the classes below are AVFoundation's,
// and `NSClassFromString` only finds a class whose image is already in the process.
import AVFoundation
import Combine
import ObjectiveC

/// AirPods' listening modes — Off, Transparency, Adaptive, Noise Cancellation — the row Control
/// Centre's Sound module puts under a pair that has them, and the one thing about a pair of
/// AirPods on a Mac that has always meant opening a menu.
///
/// None of it is public API. AVFoundation keeps it on two private classes: `AVOutputContext`,
/// whose `sharedSystemAudioContext` is the system's own audio route, and the `AVOutputDevice`s in
/// that context's `outputDevices`, each of which lists the modes it has
/// (`availableBluetoothListeningModes`), says which one is on (`currentBluetoothListeningMode`)
/// and takes a new one (`setCurrentBluetoothListeningMode:error:`) — the calls NoiseBuddy made
/// public knowledge of. So none of it is trusted to exist: every class is found by name, every
/// method is asked for before it is called and has its return type checked before it is cast,
/// and anything missing leaves `isAvailable` false and every control for it hidden. Never a
/// crash, and never a row of pills that does nothing.
///
/// AVFoundation checks, inside the calling process, for an entitlement to the system-wide context
/// (`com.apple.avfoundation.allow-system-wide-context`) — NoiseBuddy got past it by rebinding the
/// entitlement lookup — and an ad-hoc signed app does not hold it. Where that check refuses, the
/// context or its devices come back empty, that is logged once, and the pills stay hidden; nothing
/// here tries to talk AVFoundation out of its check.
///
/// The route changes without telling anybody — a pair taken out of the case becomes the output a
/// moment later — so it is polled: every two seconds, slower on battery, only while something
/// that shows it is on screen, and never while AVFoundation is refusing the context.
final class AirPodsControl: ObservableObject {
    static let shared = AirPodsControl()

    // MARK: - The modes

    /// A listening mode, in the order Control Centre lists them.
    enum Mode: String, CaseIterable, Identifiable {
        case off, transparency, adaptive, noiseCancellation

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .transparency: return "Transparency"
            case .adaptive: return "Adaptive"
            case .noiseCancellation: return "Noise Cancellation"
            }
        }

        /// The glyphs Control Centre draws, newest first, each followed by one that every macOS
        /// this app runs on has: a name SF Symbols does not know draws as nothing at all, and a
        /// pill with nothing on it is a pill nobody can read.
        var symbolCandidates: [String] {
            switch self {
            case .off: return ["person.fill"]
            case .transparency: return ["person.wave.2.fill", "waveform"]
            case .adaptive: return ["person.and.background.striped.horizontal", "circle.lefthalf.filled"]
            case .noiseCancellation: return ["person.and.background.dotted", "headphones"]
            }
        }

        /// The first of `symbolCandidates` this Mac can draw, worked out once.
        var symbol: String { Self.resolvedSymbols[self] ?? symbolCandidates.last ?? "headphones" }

        private static let resolvedSymbols: [Mode: String] = Dictionary(uniqueKeysWithValues: allCases.map { mode in
            (mode, AirPodsControl.glyph(from: mode.symbolCandidates) {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
            })
        })
    }

    /// There is a pair on the route that offers a choice of modes, and a way to set one. Every
    /// control for the modes is drawn only while this is true.
    @Published private(set) var isAvailable = false
    /// What it offers, in Control Centre's order: two at least, while `isAvailable`.
    @Published private(set) var modes: [Mode] = []
    /// The mode it is in, or nil when it names one the island cannot read.
    @Published private(set) var current: Mode?
    /// The pair the modes belong to, as AVFoundation names it — for telling which row of the
    /// Bluetooth list, and which Bluetooth card, the pills go on.
    @Published private(set) var deviceName: String?
    /// AVFoundation's identifier for the same device. For a Bluetooth pair it carries the
    /// radio's address, which is a surer match than a name somebody may have given two pairs.
    @Published private(set) var deviceIdentifier: String?

    static let pollInterval: TimeInterval = 2
    /// How long a mode the island set is shown before a reading that disagrees is believed. The
    /// buds take a moment to switch and the route reports the old mode until they have.
    static let writeSettle: TimeInterval = 2

    // MARK: - Pure rules

    /// Which mode one of AVFoundation's names is. Read by what the name says rather than matched
    /// whole: the prefix — `AVOutputDeviceBluetoothListeningMode` — is exactly the part a rename
    /// would touch, and the words after it are what the modes are called everywhere. Transparency
    /// is asked about first, so a name for Adaptive Transparency, which is a kind of Transparency
    /// and not the Adaptive mode, is read as the mode it is.
    static func mode(named raw: String) -> Mode? {
        let name = raw.lowercased()
        if name.contains("transparency") { return .transparency }
        if name.contains("adaptive") || name.hasSuffix("automatic") { return .adaptive }
        if name.contains("noisecancellation") || name.hasSuffix("noisecanceling") { return .noiseCancellation }
        if name.hasSuffix("normal") || name.hasSuffix("off") { return .off }
        return nil
    }

    /// What one output device on the route said about itself, as plain values.
    struct Reading: Equatable {
        var name: String
        var identifier: String
        /// Its `availableBluetoothListeningModes`, as given.
        var available: [String]
        /// Its `currentBluetoothListeningMode`, as given.
        var current: String?
    }

    /// The pair the pills are for, and what they offer.
    struct Choice: Equatable {
        /// Where it stood in the route's list, so the live object can be found again.
        var index: Int
        var name: String
        var identifier: String
        /// The modes, in Control Centre's order.
        var modes: [Mode]
        /// The exact name the device gave each mode — what is written back to it.
        var names: [Mode: String]
        /// Nil when the device names a mode it did not offer, or one the island cannot read:
        /// no pill is lit rather than the wrong one.
        var current: Mode?
    }

    /// The first device on the route that offers a choice: at least two modes the island can
    /// name. One mode is not a choice, and a device that lists none — the Mac's speakers, a
    /// display — has nothing to put pills on. A mode listed twice counts once, under the first
    /// name it was given. Pure.
    static func choose(_ readings: [Reading]) -> Choice? {
        for (index, reading) in readings.enumerated() {
            var names: [Mode: String] = [:]
            for raw in reading.available {
                guard let parsed = Self.mode(named: raw), names[parsed] == nil else { continue }
                names[parsed] = raw
            }
            let modes = Mode.allCases.filter { names[$0] != nil }
            guard modes.count >= 2 else { continue }
            let current = reading.current.flatMap { Self.mode(named: $0) }.flatMap { modes.contains($0) ? $0 : nil }
            return Choice(index: index, name: reading.name, identifier: reading.identifier,
                          modes: modes, names: names, current: current)
        }
        return nil
    }

    /// Whether a Bluetooth device — a row of the Controls list, the card that says it connected —
    /// is the pair the pills drive. The address, where AVFoundation's identifier carries it,
    /// settles it; otherwise the name, ignoring case. Pure.
    static func isSameDevice(name: String, address: String, deviceName: String?, deviceIdentifier: String?) -> Bool {
        let flatAddress = flattened(address)
        if flatAddress.count >= 12, let deviceIdentifier, flattened(deviceIdentifier).contains(flatAddress) {
            return true
        }
        guard let deviceName else { return false }
        let a = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// An address with its separators taken out, so "AC:1D:…" and "ac-1d-…" are one address.
    private static func flattened(_ text: String) -> String {
        text.lowercased().filter { $0.isHexDigit }
    }

    /// Whether a reading replaces the mode on screen while one the island set is still on its
    /// way to the buds: at once if it agrees, and otherwise only once the wait is over. Pure.
    static func accepts(_ reading: Mode?, pending: (mode: Mode, until: TimeInterval)?, now: TimeInterval) -> Bool {
        guard let pending else { return true }
        return reading == pending.mode || now >= pending.until
    }

    /// The first glyph `exists` knows, or the last on the list — the one that is always there.
    static func glyph(from candidates: [String], exists: (String) -> Bool) -> String {
        candidates.first(where: exists) ?? candidates.last ?? "headphones"
    }

    /// Whether the route is worth asking again every few seconds: only while something that
    /// shows the pills is on screen, and only where there is something to ask — not where the
    /// class is missing, and not once AVFoundation has refused the context `refusalsToStop`
    /// times running, which its entitlement check does for the whole run of an app signed the
    /// way this one is. Asking that every two seconds only hears the same no again. Pure.
    ///
    /// A single refusal is not that. The context is also missing for a moment while coreaudiod
    /// restarts, and the poll used to be back within one beat of it; stopping at the first nil
    /// left the pills stale for as long as Controls stayed open.
    static func shouldPoll(hasBridge: Bool, refusals: Int, viewers: Int) -> Bool {
        hasBridge && refusals < refusalsToStop && viewers > 0
    }

    /// How many refusals in a row stop the poll: six seconds of no at the two-second beat, which
    /// a restarting coreaudiod has long since answered by.
    static let refusalsToStop = 3

    // MARK: - The runtime

    /// `sharedSystemAudioContext` and every getter here: an object back, at +0.
    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
    /// `setCurrentBluetoothListeningMode:error:`.
    private typealias SetModeWithError = @convention(c) (AnyObject, Selector, AnyObject,
                                                          UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Bool
    /// `setListeningMode:`, the shape the same setter has had under its other name.
    private typealias SetModePlain = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    /// A `supports…` question, where a device answers one.
    private typealias Question = @convention(c) (AnyObject, Selector) -> Bool

    /// The three calls a device answers to, under the names they are known by. The first set is
    /// the one NoiseBuddy and every tool after it has used; the second is the shorter spelling
    /// the same calls are sometimes written with, asked for only when the first is not there.
    struct Names: Equatable {
        let available: String
        let current: String
        let set: String
        /// Whether the setter takes an `NSError **` after the mode.
        let takesError: Bool
    }

    static let knownNames: [Names] = [
        Names(available: "availableBluetoothListeningModes", current: "currentBluetoothListeningMode",
              set: "setCurrentBluetoothListeningMode:error:", takesError: true),
        Names(available: "availableListeningModes", current: "listeningMode",
              set: "setListeningMode:", takesError: false),
    ]

    /// Asked of a device when it answers them: a device that says it has no listening modes is
    /// believed, whatever its list says.
    static let supportQuestions = ["supportsBluetoothListeningModes", "supportsListeningModes"]

    /// Where AVFoundation has kept the class. It has lived in AVFoundation itself; newer systems
    /// move routing into AVRouting, which is opened only if the class is not already there.
    private static let routingFrameworks = [
        "/System/Library/Frameworks/AVRouting.framework/AVRouting",
        "/System/Library/PrivateFrameworks/AVRouting.framework/AVRouting",
    ]

    /// The context class and its one class method, found once.
    private struct Bridge {
        let contextClass: AnyClass
        let shared: ObjectGetter
        let sharedSelector: Selector

        static func load() -> Bridge? {
            var found: AnyClass? = NSClassFromString("AVOutputContext")
            if found == nil {
                for path in AirPodsControl.routingFrameworks where dlopen(path, RTLD_NOW) != nil {
                    found = NSClassFromString("AVOutputContext")
                    if found != nil { break }
                }
            }
            guard let contextClass = found else {
                IslandLog.audio.notice("no AVOutputContext; the AirPods listening modes stay hidden")
                return nil
            }
            let selector = NSSelectorFromString("sharedSystemAudioContext")
            guard let method = class_getClassMethod(contextClass, selector), AirPodsControl.returnsObject(method) else {
                IslandLog.audio.notice("AVOutputContext has no sharedSystemAudioContext; the listening modes stay hidden")
                return nil
            }
            return Bridge(contextClass: contextClass,
                          shared: unsafeBitCast(method_getImplementation(method), to: ObjectGetter.self),
                          sharedSelector: selector)
        }

        /// The system's audio context, or nothing when AVFoundation will not hand it over.
        func context() -> NSObject? {
            guard let raw = shared(contextClass as AnyObject, sharedSelector) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? NSObject
        }
    }

    /// Whether a method gives back an object — `@`, however it is qualified.
    private static func returnsObject(_ method: Method) -> Bool {
        returnType(method).hasPrefix("@")
    }

    /// Whether a method gives back a BOOL: `B` where BOOL is a bool, `c` where it is a char.
    private static func returnsBool(_ method: Method) -> Bool {
        let type = returnType(method)
        return type == "B" || type == "c"
    }

    private static func returnType(_ method: Method) -> String {
        let raw = method_copyReturnType(method)
        defer { free(raw) }
        return String(cString: raw)
    }

    /// The implementation of `name` on `object`, when the object answers to it and the method's
    /// return type is `check`'s.
    private static func method(_ object: NSObject, _ name: String, check: (Method) -> Bool) -> (Selector, IMP)? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector), check(method) else { return nil }
        return (selector, method_getImplementation(method))
    }

    /// An object-returning getter's answer, at +0.
    private static func object(_ object: NSObject, _ name: String) -> AnyObject? {
        guard let found = method(object, name, check: returnsObject) else { return nil }
        let (selector, imp) = found
        let getter = unsafeBitCast(imp, to: ObjectGetter.self)
        guard let raw = getter(object, selector) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    private let bridge: Bridge?
    /// The device the pills drive, with the names it answered to.
    private var live: (device: NSObject, names: Names, choice: Choice)?
    private var viewers = 0
    private var timer: Timer?
    private var energyCancellable: AnyCancellable?
    private var pending: (mode: Mode, until: TimeInterval)?
    /// How many times running AVFoundation has given no context, up to `refusalsToStop`. The
    /// poll stops once it gets there (see `shouldPoll`); the route is still read when a viewer
    /// appears or a Bluetooth card asks, and the moment the context answers this goes back to
    /// nothing and the poll starts again.
    private var contextRefusals = 0
    /// Each said once per run rather than every two seconds.
    private var reportedNoContext = false
    private var reportedNoDevices = false

    /// Where the route is read: the context, its `outputDevices`, and each device's name,
    /// identifier and modes, every one a call through a private class into the audio server.
    /// They were asked on the main thread as Controls appeared, inside the section's slide-in,
    /// and every two seconds after for as long as it was up. Serial, one reading at a time
    /// (`pass`), and shown on the main thread, the way `PairedDevices` reads the paired list.
    private let queue = DispatchQueue(label: "com.macnotchisland.airpods", qos: .userInitiated)
    /// Main thread.
    private var pass = RadioPass()
    /// Each reading is numbered as it is asked for, and only one newer than the last shown is
    /// shown (`showsReading`). Main thread.
    private var readingsAsked = 0
    private var readingShown = 0

    private init() {
        bridge = RenderMode.isGallery ? nil : Bridge.load()
    }

    // MARK: - Reading

    /// What one look at the route found.
    private enum Route {
        /// AVFoundation gave no system audio context.
        case noContext
        /// The context gave no list of devices to ask.
        case noDevices
        /// The device the pills drive, with the names it answered to, or nil where no device on
        /// the route offers a choice.
        case read((device: NSObject, names: Names, choice: Choice)?)
    }

    /// Asks for the route on `queue` and shows it when it comes. Main thread; returns at once.
    func refresh() {
        guard let bridge, !RenderMode.isGallery else { return publish(nil) }
        guard pass.start() else { return }
        readingsAsked += 1
        let ticket = readingsAsked
        queue.async { [weak self] in
            let route = Self.read(bridge)
            DispatchQueue.main.async {
                guard let self else { return }
                let again = self.pass.finish()
                self.show(route, ticket: ticket)
                // Asked again while this one was out: the route may have changed hands since.
                if again { self.refresh() }
            }
        }
    }

    /// Reads the route here and now and shows it before returning, for `offers`, which has to
    /// answer there and then: once for each pair that connects, on the main thread, as it always
    /// was. Not by waiting on `queue`, which would hold the main thread for a reading already out
    /// as well as its own, and could never finish if AVFoundation ever wanted the main thread
    /// for either. A reading out on the queue meanwhile lands afterwards, older, and is not shown.
    private func refreshNow() {
        guard let bridge, !RenderMode.isGallery else { return publish(nil) }
        readingsAsked += 1
        show(Self.read(bridge), ticket: readingsAsked)
    }

    /// Whether a reading numbered `ticket` is shown, the last shown being `shown`: only when it
    /// was asked for after that one. A reading asked for on the spot (`offers`) goes ahead of
    /// one still on its way back from the queue, which must not put the older route back. Pure.
    static func showsReading(ticket: Int, shown: Int) -> Bool {
        ticket > shown
    }

    /// One look at the route. On `queue`, or on the main thread for `offers`.
    private static func read(_ bridge: Bridge) -> Route {
        guard let context = bridge.context() else { return .noContext }
        guard let devices = object(context, "outputDevices") as? [NSObject] else { return .noDevices }
        var readings: [Reading] = []
        var names: [Names?] = []
        for device in devices {
            let lookup = Self.names(for: device)
            names.append(lookup)
            guard let found = lookup, saysItSupportsModes(device) else {
                readings.append(Reading(name: "", identifier: "", available: [], current: nil))
                continue
            }
            readings.append(Reading(name: (object(device, "name") as? String) ?? "",
                                    identifier: (object(device, "deviceID") as? String) ?? "",
                                    available: (object(device, found.available) as? [String]) ?? [],
                                    current: object(device, found.current) as? String))
        }
        guard let choice = choose(readings), let found = names[choice.index] else { return .read(nil) }
        return .read((devices[choice.index], found, choice))
    }

    /// Where every reading lands. Main thread.
    private func show(_ route: Route, ticket: Int) {
        guard Self.showsReading(ticket: ticket, shown: readingShown) else { return }
        readingShown = ticket
        var refusals = 0
        if case .noContext = route { refusals = min(contextRefusals + 1, Self.refusalsToStop) }
        let polled = Self.shouldPoll(hasBridge: true, refusals: contextRefusals, viewers: viewers)
        contextRefusals = refusals
        // Stops the poll, or starts it again, where that answer changed it.
        if polled != Self.shouldPoll(hasBridge: true, refusals: refusals, viewers: viewers) { schedule() }
        switch route {
        case .noContext:
            if !reportedNoContext {
                reportedNoContext = true
                IslandLog.audio.notice("AVFoundation gave no system audio context; the listening modes stay hidden")
            }
            publish(nil)
        case .noDevices:
            if !reportedNoDevices {
                reportedNoDevices = true
                IslandLog.audio.error("the system audio context has no outputDevices to ask")
            }
            publish(nil)
        case .read(let found):
            guard let found else { return publish(nil) }
            live = found
            publish(found.choice)
        }
    }

    /// The first set of names this device answers every one of, read and write.
    private static func names(for device: NSObject) -> Names? {
        knownNames.first { names in
            method(device, names.available, check: returnsObject) != nil
                && method(device, names.current, check: returnsObject) != nil
                && method(device, names.set, check: { names.takesError ? returnsBool($0) : true }) != nil
        }
    }

    /// False only when the device answers a `supports…` question and says no.
    private static func saysItSupportsModes(_ device: NSObject) -> Bool {
        for name in supportQuestions {
            guard let found = method(device, name, check: returnsBool) else { continue }
            let (selector, imp) = found
            return unsafeBitCast(imp, to: Question.self)(device, selector)
        }
        return true
    }

    private func publish(_ choice: Choice?) {
        if choice == nil { live = nil }
        let available = choice != nil
        if isAvailable != available { isAvailable = available }
        let modes = choice?.modes ?? []
        if self.modes != modes { self.modes = modes }
        if deviceName != choice?.name { deviceName = choice?.name }
        if deviceIdentifier != choice?.identifier { deviceIdentifier = choice?.identifier }
        let reading = choice?.current
        guard Self.accepts(reading, pending: pending, now: LocalWrite.now()) else { return }
        pending = nil
        if current != reading { current = reading }
    }

    /// Whether the pills drive this Bluetooth device.
    func drives(name: String, address: String) -> Bool {
        isAvailable && Self.isSameDevice(name: name, address: address,
                                         deviceName: deviceName, deviceIdentifier: deviceIdentifier)
    }

    /// Reads the route now and says whether the pills would go on this device: for the card that
    /// announces a pair, which has to know how tall to be before anything is watching.
    func offers(name: String, address: String) -> Bool {
        refreshNow()
        return drives(name: name, address: address)
    }

    // MARK: - Writing

    /// Puts the pair in `mode`. Shown at once; the route catches up.
    func set(_ mode: Mode) {
        guard let live, let raw = live.choice.names[mode] else { return }
        let device = live.device
        let selector = NSSelectorFromString(live.names.set)
        guard let method = class_getInstanceMethod(type(of: device), selector) else {
            IslandLog.audio.error("the listening-mode setter has gone from \(live.choice.name, privacy: .public)")
            return refresh()
        }
        let imp = method_getImplementation(method)
        var ok = true
        if live.names.takesError {
            var error: UnsafeMutableRawPointer?
            ok = withUnsafeMutablePointer(to: &error) { slot in
                unsafeBitCast(imp, to: SetModeWithError.self)(device, selector, raw as NSString, slot)
            }
            if !ok {
                // Handed back autoreleased: borrowed, never released here.
                let given = error.flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? NSError }
                let reason = given?.localizedDescription ?? "no reason given"
                let name = live.choice.name
                IslandLog.audio.error("\(name, privacy: .public) refused \(raw, privacy: .public): \(reason, privacy: .public)")
            }
        } else {
            unsafeBitCast(imp, to: SetModePlain.self)(device, selector, raw as NSString)
        }
        guard ok else { return refresh() }
        pending = (mode, LocalWrite.now() + Self.writeSettle)
        if current != mode { current = mode }
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

    /// Starts the poll afresh, or leaves it stopped where `shouldPoll` says there is nothing to
    /// poll for.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        // Nothing to poll for where the class is missing, or where the context has been refused
        // time after time: neither comes back by being asked every two seconds. A refused
        // context is asked again only by `refresh`, which a viewer appearing or a Bluetooth card
        // still calls, and which starts the poll itself if the answer changes.
        guard Self.shouldPoll(hasBridge: bridge != nil, refusals: contextRefusals, viewers: viewers) else { return }
        let interval = Self.pollInterval * EnergyPolicy.shared.pollingMultiplier
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
