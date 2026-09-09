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

    private init() {}

    func set(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
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
        guard let path = Self.candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return [] }
        return (0..<3).compactMap { _ in NSSound(contentsOfFile: path, byReference: true) }
    }()
    private var nextVoice = 0

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
    /// Whether this Mac can actually do what the key asks. A Mac driving only external
    /// displays has no brightness to set, and an HDMI output has no level of its own; keys we
    /// cannot answer are left for macOS rather than swallowed into silence, which is what
    /// made them dead keys.
    private var canSetVolume = true
    private var canSetBrightness = true

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
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
        SystemHUDReplacement.shared.set(false)
        trustTimer?.invalidate()
        trustTimer = nil
        lastVolume = nil
        lastMuted = nil
        lastBrightness = nil

        lock.lock()
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
        }
        timer.tolerance = 1
        trustTimer = timer
    }

    /// Access was taken away: let the tap go and stop claiming the keys.
    private func dropTap() {
        SystemHUDReplacement.shared.set(false)
        lock.lock()
        let port = tapPort
        tapPort = nil
        lock.unlock()
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop = tapRunLoop { CFRunLoopStop(loop) }
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

        let mask = CGEventMask(1 << 14) // NSEvent.EventType.systemDefined
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: mediaKeyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            tapFailures += 1
            NSLog("Notch Island: could not create the media-key event tap (attempt \(tapFailures)); the system HUD stays in charge.")
            // Trust can take a moment to settle after the prompt, so retry a few times.
            if tapFailures < 5 { pollForTrust() }
            return
        }
        tapFailures = 0
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            NSLog("Notch Island: could not create a run loop source for the media-key event tap.")
            CFMachPortInvalidate(port)
            return
        }

        lock.lock()
        tapPort = port
        lock.unlock()
        CGEvent.tapEnable(tap: port, enable: true)
        SystemHUDReplacement.shared.set(CGEvent.tapIsEnabled(tap: port))
        refreshCapabilities()

        // The tap runs on its own thread: a synchronous tap on a busy main thread would
        // delay every key press system-wide and get itself disabled for timing out.
        let thread = Thread { [weak self] in
            self?.runTapLoop(source: source)
        }
        thread.name = "com.notchisland.mediakeys"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    private func runTapLoop(source: CFRunLoopSource) {
        let loop = CFRunLoopGetCurrent()
        lock.lock()
        if stopRequested {
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
        DispatchQueue.main.async { SystemHUDReplacement.shared.set(live) }
        NSLog("Notch Island: the media-key event tap was disabled by the system; re-enabled: \(live).")
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

    /// Read on the tap thread, written on the main one.
    private func canAnswer(_ keyCode: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch keyCode {
        case MediaKey.brightnessUp, MediaKey.brightnessDown: return canSetBrightness
        default: return canSetVolume
        }
    }

    /// Asks the hardware what it can do. Cheap, and only ever from the main thread: when the
    /// tap goes up, and after each key, so plugging a display in or picking a new output
    /// corrects the answer by the next press.
    private func refreshCapabilities() {
        let brightnessOK = brightness.currentBrightness() != nil
        let volumeOK: Bool
        if AudioMonitor.readOutputVolume() != nil {
            volumeOK = true
        } else if let output = AudioOutputs.currentOutput() {
            volumeOK = AudioOutputs.hasVolumeControl(output.id)
        } else {
            volumeOK = false
        }
        lock.lock()
        canSetBrightness = brightnessOK
        canSetVolume = volumeOK
        lock.unlock()
    }

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
        // Plugging a display in or picking a different output changes what the keys can do,
        // so the answer is refreshed by the press that follows.
        refreshCapabilities()
    }

    private func adjustVolume(delta: Int, step: Float, isRepeat: Bool, flags: CGEventFlags) {
        // A remembered level belongs to the device it was read from.
        let device = AudioMonitor.defaultOutputDevice()
        if device != lastVolumeDevice {
            lastVolume = nil
            lastMuted = nil
            lastVolumeDevice = device
        }
        // Some outputs — HDMI, a few AirPlay targets — carry the sound at whatever level the
        // thing at the other end is set to. The key has already been swallowed by the time we
        // get here, so saying so is the only alternative to the press doing nothing at all.
        // The last level read from some *other* device is not an answer either, so it is not
        // used as one.
        // The remembered level stands in for a read that failed on the same device; only a
        // device that has no level at all is a device with nothing to say.
        guard let current = AudioMonitor.readOutputVolume() ?? lastVolume else {
            lastVolume = nil
            // Only call it unavailable when the device really has no control of its own; a
            // read that merely failed is not a read that could never succeed, and should not
            // be reported as one.
            guard !isRepeat, Preferences.shared.volumeHUDEnabled,
                  let output = AudioOutputs.currentOutput(),
                  !AudioOutputs.hasVolumeControl(output.id) else { return }
            ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud,
                                                           content: .hud(.unavailableVolume(output: output)),
                                                           priority: 85),
                                            duration: 1.5, haptic: false)
            return
        }
        var muted = AudioMonitor.readOutputMute() ?? lastMuted ?? false
        let target = Self.stepped(from: current, delta: delta, step: step)
        // Holding a key against 0 or 1 should not keep re-announcing the same value.
        if isRepeat, target == current, !(muted && delta > 0) {
            lastVolume = target
            return
        }
        let applied = AudioMonitor.writeOutputVolume(target)
        if applied { lastVolume = target }
        // Turning the volume up unmutes, the way the system keys do.
        if muted, delta > 0, AudioMonitor.writeOutputMute(false) {
            muted = false
            lastMuted = false
        }
        // The system plays its click as part of answering the key; since the key never got
        // there, the click has to come from here or it is simply gone.
        if applied, !muted { VolumeFeedbackSound.shared.play(flags: flags) }
        postVolumeHUD(level: applied ? target : current, muted: muted)
    }

    private func toggleMute() {
        guard let muted = AudioMonitor.readOutputMute() ?? lastMuted else { return }
        let next = !muted
        guard AudioMonitor.writeOutputMute(next) else { return }
        lastMuted = next
        guard Preferences.shared.volumeHUDEnabled else { return }
        let activity = IslandActivity(id: "silent", kind: .silent, content: .silent(SilentState(isSilent: next)), priority: 85)
        ActivityCenter.shared.showAlert(activity, duration: 2, haptic: false)
    }

    private func adjustBrightness(delta: Int, step: Float, isRepeat: Bool) {
        guard let current = brightness.currentBrightness() ?? lastBrightness else { return }
        let target = Self.stepped(from: current, delta: delta, step: step)
        if isRepeat, target == current {
            lastBrightness = target
            return
        }
        guard brightness.setBrightness(target) else { return }
        lastBrightness = target
        brightness.notifyChange(value: target)
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
