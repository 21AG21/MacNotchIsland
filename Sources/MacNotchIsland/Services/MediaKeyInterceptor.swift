import AppKit
import ApplicationServices
import Combine
import CoreAudio
import CoreGraphics

/// Opt-in replacement of the system volume / brightness bezel.
///
/// A CGEventTap on `NSEvent.EventType.systemDefined` (raw value 14) sees the media keys
/// before OSDUIHelper does. For the keys we own we apply the change ourselves, show the
/// island HUD and swallow the event, so the system bezel never appears; every other event
/// is passed straight through. Keyboard illumination is deliberately left alone — there is
/// no reliable API for the backlight, so those keys keep their system behaviour.
///
/// The tap needs Accessibility trust. Without it `CGEvent.tapCreate` returns nil, so we
/// prompt once and then poll until the user grants it, at which point the tap is installed.
/// Everything here fails soft: if anything goes wrong the system bezel simply stays.
/// Whether the island is really standing in for the system's volume and brightness bezel.
///
/// True only while the event tap is installed and carrying the media keys. It matters because
/// the island must not draw a bezel of its own beside one macOS is already drawing: two
/// heads-up displays for one keypress is worse than either alone, and it is the first thing
/// anyone notices. While this is false the island says nothing about volume or brightness and
/// leaves the job to the system.
final class SystemHUDReplacement: ObservableObject {
    static let shared = SystemHUDReplacement()

    /// The tap is up, so every media key reaches the island and none reaches OSDUIHelper.
    @Published private(set) var isActive = false

    /// What this Mac can actually be asked for.
    ///
    /// A key the island cannot answer is handed back to macOS, which then draws its own bezel
    /// for it — so a display the island put up for that change would be the second one, which
    /// is the whole thing this is here to stop. Kept here rather than beside the tap so there
    /// is one store, one lock and one default: two copies with opposite defaults and a hop
    /// between them is how "is the island answering this?" gets two answers at once.
    ///
    /// Read from the tap thread as well as the main one, so it lives behind a lock rather
    /// than in a published property. False until the first probe has actually asked.
    struct Capabilities: Equatable {
        var volume = false
        var mute = false
        var brightness = false
    }

    private let lock = NSLock()
    private var capabilities = Capabilities()

    private init() {}

    /// Safe from any thread.
    func can(_ keyPath: KeyPath<Capabilities, Bool>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return capabilities[keyPath: keyPath]
    }

    func setCapabilities(_ new: Capabilities) {
        lock.lock()
        capabilities = new
        lock.unlock()
    }

    /// Whether a change of this kind is the island's to announce. Main thread.
    var answersVolume: Bool { isActive && can(\.volume) }
    var answersMute: Bool { isActive && can(\.mute) }
    var answersBrightness: Bool { isActive && can(\.brightness) }

    func set(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
    }

    /// The tap is gone for good — not merely disabled — so the answers go with it.
    ///
    /// Only on a real teardown. Clearing them whenever the tap read as off cost more than it
    /// bought: `answersVolume` and friends already require `isActive`, so a stale `true`
    /// underneath a down tap says nothing, while an emptied set survives the tap coming back
    /// and hands every media key to macOS — bezel and all — until the next probe lands
    /// seconds later.
    func forgetCapabilities() {
        setCapabilities(Capabilities())
        set(false)
    }
}

/// The click macOS plays when the volume keys change the level.
///
/// Taking the key means taking the sound with it, and its absence is the kind of small
/// missing thing that makes a replacement feel like a downgrade even when it looks better.
/// The user's own Sound setting decides whether it plays; holding Shift inverts it for one
/// press, the way the system's does. Everything about it fails soft: an unknown macOS that
/// keeps the file somewhere new simply gets no click.
final class VolumeFeedbackSound {
    static let shared = VolumeFeedbackSound()

    /// Where macOS has kept the file across releases. The first one that is really there wins.
    static let candidates = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/volume_change.aif",
        "/System/Library/Components/CoreAudio.component/Contents/Resources/SystemSounds/system/volume_change.aif",
        "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
    ]

    /// `com.apple.sound.beep.feedback` in the global domain — the "Play feedback when volume
    /// is changed" checkbox in Sound settings.
    static let feedbackKey = "com.apple.sound.beep.feedback"

    /// A handful of copies, used in turn. Holding a volume key repeats far faster than one
    /// click takes to finish, and restarting a single sound on each repeat cuts every click
    /// off a few milliseconds in and turns sixteen notches into a buzz.
    private lazy var voices: [NSSound] = {
        // The first path that both exists and opens — a file that is there but that NSSound
        // will not decode should fall through to the next candidate, not end the search.
        var best: [NSSound] = []
        for path in Self.candidates where FileManager.default.fileExists(atPath: path) {
            // The first one is the probe as well as a voice: a file that is there and will not
            // open falls through to the next candidate rather than ending the search.
            guard let first = NSSound(contentsOfFile: path, byReference: true) else { continue }
            let voices = [first] + (1..<Self.voiceCount).compactMap { _ in
                NSSound(contentsOfFile: path, byReference: true)
            }
            if voices.count == Self.voiceCount { return voices }
            // A short pool is the buzz again, so it is only ever a last resort.
            if voices.count > best.count { best = voices }
        }
        return best
    }()
    private var nextVoice = 0
    /// Enough that a click is never cut off by the next one at a key's repeat rate.
    static let voiceCount = 3

    private init() {}

    /// The checkbox as the system has it, or nil on a Mac that has never been asked.
    static var systemSetting: Bool? {
        (UserDefaults.standard.object(forKey: feedbackKey) as? NSNumber)?.boolValue
    }

    /// Whether a press with these modifiers should click. Never having been asked means yes:
    /// that is how a Mac with speakers ships, and it is why the volume keys click out of the
    /// box. Shift on its own flips the answer for that one press, the way the system's does;
    /// Shift with Option is the quarter-step gesture and is left alone.
    static func shouldPlay(flags: CGEventFlags, setting: Bool?) -> Bool {
        let inverting = flags.contains(.maskShift) && !flags.contains(.maskAlternate)
        return (setting ?? true) != inverting
    }

    func play(flags: CGEventFlags) {
        guard Self.shouldPlay(flags: flags, setting: Self.systemSetting), !voices.isEmpty else { return }
        let sound = voices[nextVoice % voices.count]
        nextVoice = (nextVoice + 1) % voices.count
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

final class MediaKeyInterceptor {
    /// Key codes from IOKit's `ev_keymap.h` (`NX_KEYTYPE_*`), redeclared so we do not
    /// depend on a private header being visible to Swift.
    enum MediaKey {
        static let soundUp = 0
        static let soundDown = 1
        static let brightnessUp = 2
        static let brightnessDown = 3
        static let mute = 7
        static let illuminationUp = 21
        static let illuminationDown = 22
    }

    /// The keys we take over. Illumination is deliberately absent.
    static let interceptedKeyCodes: Set<Int> = [MediaKey.soundUp, MediaKey.soundDown,
                                                MediaKey.brightnessUp, MediaKey.brightnessDown,
                                                MediaKey.mute]

    /// `NSEvent.EventType.systemDefined`, which CGEventType has no case for.
    static let systemDefinedEventType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    static let auxControlSubtype: Int16 = 8

    /// How many times a tap that will not be created is asked for again. The watch timer
    /// runs for as long as the feature is on, so without a cap it would ask forever and write
    /// a line to the system log every few seconds for the life of the process.
    static let maxTapAttempts = 5

    /// One notch of the macOS volume / brightness bar.
    static let coarseStep: Float = 1.0 / 16.0
    /// The Shift+Option quarter notch.
    static let fineStep: Float = 1.0 / 64.0

    static var isTrusted: Bool { AXIsProcessTrusted() }

    private let brightness = BrightnessMonitor()

    /// How often the tap is checked over: often enough that revoking Accessibility stops the
    /// island claiming the keys within a few seconds, rarely enough to cost nothing.
    static let watchInterval: TimeInterval = 5

    // Main thread only.
    private var running = false
    private var promptedForTrust = false
    private var trustTimer: Timer?
    private var tapThread: Thread?
    private var tapFailures = 0
    private var lastVolume: Float?
    private var lastMuted: Bool?
    private var lastBrightness: Float?
    /// The device the remembered level belongs to. A level read from some other output is not
    /// a level for this one, and stepping from it would write a stranger's number.
    private var lastVolumeDevice: AudioDeviceID?

    // Shared with the tap thread.
    private let lock = NSLock()
    private var tapPort: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var stopRequested = false
    /// Bumped by every install and every teardown, so both the capability probe's completion
    /// and the tap thread itself can tell whether the tap they were started for is still the
    /// tap that exists.
    private var installGeneration = 0

    /// Ends the install that is running, if any, and names the one that replaces it.
    /// Caller must hold `lock`.
    private func nextGenerationLocked() -> Int {
        installGeneration &+= 1
        return installGeneration
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return installGeneration == generation
    }


    // MARK: - Lifecycle

    func start() {
        guard !running else {
            // Already up. `ServiceHub` calls this again on every preference change, and one of
            // them decides which keys are the island's to take at all.
            refreshCapabilities()
            return
        }
        running = true
        // Switching the feature off and on again is the user's way of saying "try again", and
        // it has to actually try: without this a run of failures would be permanent for the
        // life of the process, with nothing but a relaunch to clear it.
        tapFailures = 0
        lock.lock()
        stopRequested = false
        lock.unlock()
        if Self.isTrusted {
            installTap()
        } else {
            requestTrust()
        }
        // Kept running either way: on the way in it waits for access to be granted, and
        // afterwards it notices access being taken away.
        pollForTrust()
    }

    func stop() {
        guard running else { return }
        running = false
        SystemHUDReplacement.shared.forgetCapabilities()
        trustTimer?.invalidate()
        trustTimer = nil
        lastVolume = nil
        lastMuted = nil
        lastBrightness = nil

        lock.lock()
        _ = nextGenerationLocked()
        stopRequested = true
        let port = tapPort
        let loop = tapRunLoop
        tapPort = nil
        lock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
        tapThread = nil
    }

    // MARK: - Accessibility trust

    /// Asks macOS to show the "allow Notch Island to control your Mac" prompt, once.
    private func requestTrust() {
        guard !promptedForTrust else { return }
        promptedForTrust = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// There is no notification for the trust state, so it is polled — both on the way in,
    /// while the user is deciding, and afterwards.
    ///
    /// Afterwards matters: revoking Accessibility invalidates the tap without calling the
    /// callback, so nothing would ever tell us the keys had gone back to macOS. The island
    /// would keep drawing its own display next to the system's — the one thing the whole
    /// arrangement exists to prevent. The interval follows the energy policy, so a forgotten
    /// prompt costs nothing on battery.
    private func pollForTrust() {
        trustTimer?.invalidate()
        let interval = Self.watchInterval * EnergyPolicy.shared.pollingMultiplier
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            guard Self.isTrusted else {
                self.dropTap()
                return
            }
            self.installTap()
            self.verifyTap()
            // Not only after a key: a key we have handed back to macOS never reaches `apply`,
            // so refreshing there alone would latch the answer off for the session the moment
            // an output with no level of its own became the default.
            self.refreshCapabilities()
        }
        timer.tolerance = 1
        trustTimer = timer
    }

    /// Access was taken away: let the tap go and stop claiming the keys.
    private func dropTap() {
        SystemHUDReplacement.shared.forgetCapabilities()
        lock.lock()
        _ = nextGenerationLocked()
        // Told to the thread the same way `stop()` tells it: a drop that lands before the
        // thread has published its run loop has no loop to stop, and without this the thread
        // would go on to run one — and to publish a `tapRunLoop` for a port that is already
        // invalid, which the next install would then stop instead of its own.
        stopRequested = true
        let port = tapPort
        let loop = tapRunLoop
        tapPort = nil
        lock.unlock()
        tapFailures = 0
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop { CFRunLoopStop(loop) }
        tapThread = nil
    }

    /// The tap can be turned off under us; say so if it has been.
    private func verifyTap() {
        lock.lock()
        let port = tapPort
        lock.unlock()
        guard let port else { return SystemHUDReplacement.shared.set(false) }
        SystemHUDReplacement.shared.set(CGEvent.tapIsEnabled(tap: port))
    }

    // MARK: - Event tap

    private func installTap() {
        lock.lock()
        let alreadyInstalled = tapPort != nil
        lock.unlock()
        guard running, !alreadyInstalled else { return }
        guard tapFailures < Self.maxTapAttempts else { return }

        let mask = CGEventMask(1 << 14) // NSEvent.EventType.systemDefined
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: mediaKeyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            tapFailures += 1
            SystemHUDReplacement.shared.set(false)
            IslandLog.keys.error("could not create the event tap; attempt \(self.tapFailures, privacy: .public) of \(Self.maxTapAttempts, privacy: .public)")
            return
        }
        // A tap is created enabled. Nothing may reach it until the island knows which keys it
        // can answer — and until a run loop is reading the port, an enabled tap is one the
        // system disables for timing out, holding up every media key on the Mac while it does.
        CGEvent.tapEnable(tap: port, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            // Counted like any other failure: the watch timer will come back every few
            // seconds for as long as the feature is on, and something that cannot be built
            // must not be asked for and logged forever.
            tapFailures += 1
            SystemHUDReplacement.shared.set(false)
            IslandLog.keys.error("no run loop source for the event tap; attempt \(self.tapFailures, privacy: .public) of \(Self.maxTapAttempts, privacy: .public)")
            CFMachPortInvalidate(port)
            return
        }
        tapFailures = 0

        lock.lock()
        tapPort = port
        // Lifted here, not only in `start()`: trust can be taken away and given back without
        // the feature ever being switched off, and the drop in between left this set.
        stopRequested = false
        let generation = nextGenerationLocked()
        lock.unlock()

        // The tap runs on its own thread: a synchronous tap on a busy main thread would delay
        // every key press system-wide and get itself disabled for timing out. Started now,
        // with the port and source it was made for, so the run loop is already reading.
        let thread = Thread { [weak self] in
            self?.runTapLoop(source: source, generation: generation)
        }
        thread.name = "com.notchisland.mediakeys"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        // Switched on only once the island knows which keys it can answer, and only if this
        // is still the tap that exists — a probe started for a tap that has since been torn
        // down and rebuilt would otherwise enable the dead one and leave the live one unread.
        refreshCapabilities { [weak self] in
            guard let self, self.running, self.isCurrent(generation) else { return }
            CGEvent.tapEnable(tap: port, enable: true)
            SystemHUDReplacement.shared.set(CGEvent.tapIsEnabled(tap: port))
        }
    }

    private func runTapLoop(source: CFRunLoopSource, generation: Int) {
        let loop = CFRunLoopGetCurrent()
        lock.lock()
        // This thread belongs to one install. A teardown that landed before it got here has
        // already invalidated its port, and a rebuild after that has a thread of its own:
        // publishing this loop would give the next teardown the wrong one to stop and leave
        // the live tap unread. `stopRequested` alone did not cover the rebuild, which clears
        // it again.
        guard !stopRequested, installGeneration == generation else {
            lock.unlock()
            return
        }
        tapRunLoop = loop
        lock.unlock()

        CFRunLoopAddSource(loop, source, .commonModes)
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, source, .commonModes)

        lock.lock()
        // Only clear it when a restart has not already published a newer loop.
        if tapRunLoop === loop { tapRunLoop = nil }
        lock.unlock()
    }

    /// macOS disables a tap that timed out or that the user interrupted; turn it back on,
    /// and only claim the keys again once it says it really is carrying them.
    fileprivate func reenableTap() {
        lock.lock()
        let port = tapPort
        lock.unlock()
        guard let port else {
            DispatchQueue.main.async { SystemHUDReplacement.shared.set(false) }
            return
        }
        CGEvent.tapEnable(tap: port, enable: true)
        let live = CGEvent.tapIsEnabled(tap: port)
        // Asked again on the main thread rather than asserted from here: by the time this
        // runs the feature may have been switched off, and a stale `true` would leave the
        // island drawing its display beside the system's with no tap at all behind it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.verifyTap()
        }
        IslandLog.keys.error("the event tap was disabled by the system; re-enabled: \(live, privacy: .public)")
    }

    /// Called on the tap thread. Returns true when the event should be swallowed.
    fileprivate func handleSystemDefined(_ event: CGEvent) -> Bool {
        var swallow = false
        autoreleasepool {
            guard let nsEvent = NSEvent(cgEvent: event),
                  nsEvent.subtype.rawValue == Self.auxControlSubtype else { return }
            let decoded = Self.decode(data1: nsEvent.data1)
            guard Self.interceptedKeyCodes.contains(decoded.keyCode) else { return }
            // A key this Mac cannot answer goes back to macOS, which still has its own bezel
            // for it. Swallowing it here would make it a dead key: no change, no display,
            // nothing at all.
            guard canAnswer(decoded.keyCode) else { return }
            swallow = true
            guard decoded.isDown else { return }
            let flags = event.flags
            DispatchQueue.main.async { [weak self] in
                self?.apply(keyCode: decoded.keyCode, isRepeat: decoded.isRepeat, flags: flags)
            }
        }
        return swallow
    }

    /// Whether this Mac can do what the key asks. A Mac driving only external displays has no
    /// brightness to set and an HDMI output has no level of its own; keys we cannot answer are
    /// left for macOS, which still has a bezel for them, rather than swallowed into silence.
    /// Asked from the tap thread.
    private func canAnswer(_ keyCode: Int) -> Bool {
        switch keyCode {
        case MediaKey.brightnessUp, MediaKey.brightnessDown:
            return SystemHUDReplacement.shared.can(\.brightness)
        case MediaKey.mute:
            return SystemHUDReplacement.shared.can(\.mute)
        default:
            return SystemHUDReplacement.shared.can(\.volume)
        }
    }

    /// Asks the hardware what it can do and writes the whole answer at once.
    ///
    /// Off the main thread because these are blocking round trips to the display server and to
    /// coreaudiod, and coreaudiod is at its busiest exactly when a device is arriving — which
    /// is the moment this most wants asking. The answer lands behind the lock the tap thread
    /// reads it through; `finished` runs on the main thread once it has.
    ///
    /// Every value is probed every time. Caching them against the device they were read from
    /// saved a dozen round trips every five seconds, off the main thread, and cost two
    /// separate latches: an answer of "no" kept for a device that had merely not finished
    /// arriving, and a cache that outlived the capabilities being cleared when the tap went
    /// down — so the same output came back permanently unanswerable. A whole answer, written
    /// once, cannot be half-stale.
    private func refreshCapabilities(then finished: (() -> Void)? = nil) {
        // What the user asked for, read here on the main thread and carried in. A display the
        // user has switched off is not a key the island should be taking: swallowing it would
        // leave that change with no bezel at all, when macOS still has a perfectly good one
        // for it. Off means off — the key goes back, whatever the hardware can do.
        let wanted = SystemHUDReplacement.Capabilities(volume: Preferences.shared.volumeHUDEnabled,
                                                       mute: Preferences.shared.volumeHUDEnabled,
                                                       brightness: Preferences.shared.brightnessHUDEnabled)
        Self.capabilityQueue.async { [weak self] in
            guard let self else { return }
            let device = AudioMonitor.defaultOutputDevice()
            // Settable, not readable: a level that can be read and not written is a key
            // swallowed into a bar that never moves, and the message written for that case is
            // guarded on this same answer.
            let answer = SystemHUDReplacement.Capabilities(
                volume: wanted.volume && AudioMonitor.outputHasVolumeControl(device: device),
                mute: wanted.mute && AudioMonitor.outputHasMuteControl(device: device),
                brightness: wanted.brightness && self.brightness.currentBrightness() != nil)
            SystemHUDReplacement.shared.setCapabilities(answer)
            if let finished { DispatchQueue.main.async(execute: finished) }
        }
    }

    private static let capabilityQueue = DispatchQueue(label: "com.notchisland.mediakeys.capabilities",
                                                       qos: .utility)

    // MARK: - Decoding

    /// Splits the `data1` payload of a system-defined media-key event.
    /// Bits 16...31 are the key code, bits 8...15 the key state (0x0A = down) and bit 0
    /// marks an auto-repeat.
    static func decode(data1: Int) -> (keyCode: Int, isDown: Bool, isRepeat: Bool) {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1
        return (keyCode, isDown, isRepeat)
    }

    /// The next notch on the macOS 16-step grid, `delta` notches away from `current`.
    /// A press always moves in the requested direction, even from between two notches.
    static func stepped(from current: Float, delta: Int, step: Float) -> Float {
        guard step > 0 else { return min(1, max(0, current)) }
        let epsilon = step / 100
        let notch: Float = delta > 0
            ? ((current + epsilon) / step).rounded(.down) + Float(delta)
            : ((current - epsilon) / step).rounded(.up) + Float(delta)
        return min(1, max(0, notch * step))
    }

    // MARK: - Applying (main thread)

    private func apply(keyCode: Int, isRepeat: Bool, flags: CGEventFlags) {
        // macOS uses quarter notches while Shift+Option are held.
        let step = (flags.contains(.maskAlternate) && flags.contains(.maskShift)) ? Self.fineStep : Self.coarseStep
        switch keyCode {
        case MediaKey.soundUp: adjustVolume(delta: 1, step: step, isRepeat: isRepeat, flags: flags)
        case MediaKey.soundDown: adjustVolume(delta: -1, step: step, isRepeat: isRepeat, flags: flags)
        case MediaKey.mute: if !isRepeat { toggleMute() }
        case MediaKey.brightnessUp: adjustBrightness(delta: 1, step: step, isRepeat: isRepeat)
        case MediaKey.brightnessDown: adjustBrightness(delta: -1, step: step, isRepeat: isRepeat)
        default: break
        }
        // A single press picks up a change at once; an auto-repeat does not, because these
        // are blocking hardware reads and a held key repeats twenty times a second. The watch
        // timer covers everything in between.
        if !isRepeat { refreshCapabilities() }
    }

    /// A remembered level or mute state belongs to the device it was read from; stepping from
    /// a stranger's number would write a stranger's number.
    private func forgetOtherDevices(_ device: AudioDeviceID) {
        guard device != lastVolumeDevice else { return }
        lastVolume = nil
        lastMuted = nil
        lastVolumeDevice = device
    }

    private func adjustVolume(delta: Int, step: Float, isRepeat: Bool, flags: CGEventFlags) {
        // Resolved once. Every one of these questions would otherwise ask the HAL which
        // device is the default all over again, six times for a press that repeats twenty
        // times a second.
        let device = AudioMonitor.defaultOutputDevice()
        forgetOtherDevices(device)
        // Some outputs — HDMI, a few AirPlay targets — carry the sound at whatever level the
        // thing at the other end is set to. The key has already been swallowed by the time we
        // get here, so saying so is the only alternative to the press doing nothing at all.
        // The remembered level stands in for a read that failed on the same device; the one
        // last read from some *other* device is not an answer and is not used as one.
        guard let current = AudioMonitor.readOutputVolume(device: device) ?? lastVolume else {
            lastVolume = nil
            // There is no level to step from, so there is nothing to set — and a swallowed
            // key that changes nothing has to say why, or it is simply a dead key. The
            // display says the level cannot be had and names the output, which is true both
            // of an HDMI target that has no control and of a device that has one but would
            // not answer just now; it does not claim the hardware is incapable. Repeats stay
            // quiet: the first press of the held key has already said it.
            if !isRepeat { postUnavailable() }
            return
        }
        var muted = AudioMonitor.readOutputMute(device: device) ?? lastMuted ?? false
        let target = Self.stepped(from: current, delta: delta, step: step)
        // Holding a key against 0 or 1 should not keep re-announcing the same value.
        if isRepeat, target == current, !(muted && delta > 0) {
            lastVolume = target
            return
        }
        AudioOutputs.markLocalWrite()
        let applied = AudioMonitor.writeOutputVolume(target, device: device)
        if applied { lastVolume = target }
        // Turning the volume up unmutes, the way the system keys do.
        if muted, delta > 0, AudioMonitor.writeOutputMute(false, device: device) {
            muted = false
            lastMuted = false
        }
        // The system plays its click as part of answering the key; since the key never got
        // there, the click has to come from here or it is simply gone.
        if applied, !muted { VolumeFeedbackSound.shared.play(flags: flags) }
        postVolumeHUD(level: applied ? target : current, muted: muted)
    }

    private func toggleMute() {
        let device = AudioMonitor.defaultOutputDevice()
        forgetOtherDevices(device)
        // The key is already swallowed by the time this runs, so every way out of here that
        // is not a change has to say something. A device that will not report or take a mute
        // gets the same answer as one with no level at all: an em dash and its name.
        guard let muted = AudioMonitor.readOutputMute(device: device) ?? lastMuted else {
            return postUnavailable()
        }
        let next = !muted
        AudioOutputs.markLocalWrite()
        guard AudioMonitor.writeOutputMute(next, device: device) else { return postUnavailable() }
        lastMuted = next
        guard Preferences.shared.volumeHUDEnabled else { return }
        let activity = IslandActivity(id: "silent", kind: .silent, content: .silent(SilentState(isSilent: next)), priority: 85)
        ActivityCenter.shared.showAlert(activity, duration: 2, haptic: false)
    }

    private func adjustBrightness(delta: Int, step: Float, isRepeat: Bool) {
        // The same rule the volume path follows: the key is already swallowed by the time
        // this runs, so a press that changes nothing has to say so rather than disappear. A
        // Mac driving only an external display over DDC can answer the first question and
        // refuse the second, and either way the bar the user expected is not coming.
        guard let current = brightness.currentBrightness() ?? lastBrightness else {
            return postUnavailableBrightness(isRepeat: isRepeat)
        }
        let target = Self.stepped(from: current, delta: delta, step: step)
        if isRepeat, target == current {
            lastBrightness = target
            return
        }
        guard brightness.setBrightness(target) else {
            return postUnavailableBrightness(isRepeat: isRepeat)
        }
        lastBrightness = target
        brightness.notifyChange(value: target)
    }

    /// Repeats stay quiet: the first press of a held key has already said it.
    private func postUnavailableBrightness(isRepeat: Bool) {
        guard !isRepeat, Preferences.shared.brightnessHUDEnabled else { return }
        var hud = LevelHUD(kind: .brightness, level: 0)
        hud.isUnavailable = true
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85),
                                        duration: 1.5, haptic: false)
    }

    /// What the island says when a key has been taken and there was nothing it could do with
    /// it: the output's name and an em dash where the number would be.
    private func postUnavailable() {
        guard Preferences.shared.volumeHUDEnabled else { return }
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud,
                                                       content: .hud(.unavailableVolume(output: AudioOutputs.currentOutput())),
                                                       priority: 85),
                                        duration: 1.5, haptic: false)
    }

    /// The CoreAudio listener in `AudioMonitor` normally reports our own write too, but it
    /// is not running when the volume HUD is the only thing switched off, and we would
    /// rather not depend on that. Posting here is safe: the alert carries the same id, so a
    /// duplicate simply replaces itself.
    private func postVolumeHUD(level: Float, muted: Bool) {
        guard Preferences.shared.volumeHUDEnabled else { return }
        let hud = LevelHUD.volume(level: Double(level), isMuted: muted, output: AudioOutputs.currentOutput())
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85),
                                        duration: 1.5, haptic: false)
    }
}

/// C callback for the tap. Runs on the tap thread; keeps no state of its own.
private func mediaKeyTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        interceptor.reenableTap()
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == MediaKeyInterceptor.systemDefinedEventType else {
        return Unmanaged.passUnretained(event)
    }
    return interceptor.handleSystemDefined(event) ? nil : Unmanaged.passUnretained(event)
}
