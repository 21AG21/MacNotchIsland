import Foundation
import Combine
import CoreAudio
import AudioToolbox

/// Watches the default output device (volume HUD, silent-mode alert) and who is recording
/// (the microphone-in-use privacy indicator, and the call card) through CoreAudio property
/// listeners.
final class AudioMonitor {
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    /// Who has the microphone, as far as this Mac will say.
    struct Microphone: Equatable {
        /// Whether anything is recording: what the orange dot shows.
        var inUse = false
        /// The processes recording, each by its bundle identifier — or its pid, where it has no
        /// bundle — on macOS 14.2 and later. Nil where that cannot be asked, or was asked and not
        /// answered. A set, so the same recorders listed in another order are no change.
        var recorders: Set<String>? = nil
    }

    /// The microphone as last read. `CallDetector` follows this rather than the dot's Bool: a
    /// call app that starts recording while something else already is changes the recorders
    /// and leaves the Bool where it was.
    @Published private(set) var microphone = Microphone()

    private var systemRegistrations: [Registration] = []
    private var outputRegistrations: [Registration] = []
    private var inputRegistrations: [Registration] = []
    /// One listener per process Core Audio knows, on whether it is taking input. Kept by process
    /// object so a change to the list adds and removes only what changed, rather than dropping
    /// and re-registering a listener on every process that has ever played a sound.
    private var processRegistrations: [AudioObjectID: Registration] = [:]
    private var outputDevice: AudioDeviceID = 0
    private var inputDevice: AudioDeviceID = 0
    private var lastVolume: Float32 = -1
    private var lastMute: Bool?
    private var running = false
    private let queue = DispatchQueue.main

    func start() {
        guard !running else { return }
        running = true
        systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject),
                                          selector: kAudioHardwarePropertyDefaultOutputDevice,
                                          scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.bindOutput() })
        systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject),
                                          selector: kAudioHardwarePropertyDefaultInputDevice,
                                          scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.bindInput() })
        if #available(macOS 14.2, *) {
            systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject),
                                              selector: kAudioHardwarePropertyProcessObjectList,
                                              scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.bindProcesses() })
        }
        bindOutput()
        bindInput()
        if #available(macOS 14.2, *) { bindProcesses() }
    }

    func stop() {
        guard running else { return }
        running = false
        remove(&systemRegistrations)
        remove(&outputRegistrations)
        remove(&inputRegistrations)
        var processes = Array(processRegistrations.values)
        remove(&processes)
        processRegistrations.removeAll()
        ActivityCenter.shared.micInUse = false
        microphone = Microphone()
    }

    // MARK: Binding

    /// Called by `start`, and by the default-output listener on `queue`, the main queue, which
    /// is where `stop` runs too — so `running` is read where it is written.
    private func bindOutput() {
        // A default-device change already queued when the monitor stopped would otherwise put
        // back listeners that nothing is left to take off, as in `bindProcesses`.
        guard running else { return }
        remove(&outputRegistrations)
        outputDevice = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        guard outputDevice != 0 else { return }
        lastVolume = readVolume() ?? -1
        lastMute = readMute()
        // Every element a level can live on, without first asking which of them this device
        // has. An aggregate or USB device that keeps its level on a channel rather than on
        // the synthesised main one would otherwise never report a change, while the
        // media-key path showed one — two behaviours for one device. See `volumeElements`
        // for why the question is not asked.
        for element in Self.volumeElements {
            outputRegistrations.append(listen(outputDevice, address: Self.volumeAddress(element: element)) {
                [weak self] in self?.volumeChanged()
            })
        }
        outputRegistrations.append(listen(outputDevice, selector: kAudioDevicePropertyMute,
                                          scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.muteChanged() })
    }

    /// The same as `bindOutput`, for the default input, and guarded for the same reason.
    private func bindInput() {
        guard running else { return }
        remove(&inputRegistrations)
        inputDevice = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        // Read even with no device: a microphone unplugged is a microphone no longer in use.
        defer { microphoneChanged() }
        guard inputDevice != 0 else { return }
        // The whole answer below 14.2, and from 14.2 on only a prompt to ask who is recording:
        // the device starting is the one thing every version reports.
        inputRegistrations.append(listen(inputDevice, selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                         scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.microphoneChanged() })
    }

    /// Follows the list of processes Core Audio knows, with a listener on each for whether it is
    /// taking input. The list alone is not enough: a process has an object from the moment it
    /// first plays or records anything, so a call app that has already rung once is on the list
    /// before its call starts, and starting to record changes only its own property.
    @available(macOS 14.2, *)
    private func bindProcesses() {
        // A change already queued when the monitor stopped would otherwise put back listeners
        // that nothing is left to take off.
        guard running else { return }
        let current = Set(Self.processObjects() ?? [])
        let gone = processRegistrations.keys.filter { !current.contains($0) }
        for process in gone {
            if var r = processRegistrations.removeValue(forKey: process) {
                _ = AudioObjectRemovePropertyListenerBlock(r.object, &r.address, queue, r.block)
            }
        }
        for process in current where processRegistrations[process] == nil {
            processRegistrations[process] = listen(process, selector: kAudioProcessPropertyIsRunningInput,
                                                   scope: kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.microphoneChanged()
            }
        }
        microphoneChanged()
    }

    // MARK: Events

    private func volumeChanged() {
        // The level is read and remembered whatever happens next: a change that is suppressed
        // is still a change, and leaving the remembered one behind would make the next
        // genuine one look like no change at all.
        guard let v = readVolume() else { return }
        let moved = abs(v - lastVolume) > 0.001
        lastVolume = v
        guard moved else { return }
        // Only once the island has taken the media keys over *and* can answer this one. A
        // key it hands back is answered by the system's bezel, and a display beside that is
        // the two-for-one-press this whole arrangement exists to stop.
        guard Preferences.shared.volumeHUDEnabled, SystemHUDReplacement.shared.answersVolume,
              !AudioOutputs.wroteRecently() else { return }
        let muted = readMute() ?? false
        let hud = LevelHUD.volume(level: Double(v), isMuted: muted, output: AudioOutputs.currentOutput())
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85), duration: 1.5, haptic: false)
    }

    private func muteChanged() {
        guard let muted = readMute() else { return }
        let moved = muted != lastMute
        lastMute = muted
        guard moved, Preferences.shared.volumeHUDEnabled, SystemHUDReplacement.shared.answersMute,
              !AudioOutputs.wroteRecently() else { return }
        let activity = IslandActivity(id: "silent", kind: .silent, content: .silent(SilentState(isSilent: muted)), priority: 85)
        ActivityCenter.shared.showAlert(activity, duration: 2, haptic: false)
    }

    private func microphoneChanged() {
        guard running else { return }
        var recorders: Set<String>?
        if #available(macOS 14.2, *) { recorders = Self.recordingProcesses().map { Set($0) } }
        let inUse = Self.micInUse(deviceRunning: readRunningSomewhere(inputDevice),
                                  hasOutput: Self.hasOutputStreams(inputDevice), recorders: recorders)
        if ActivityCenter.shared.micInUse != inUse {
            ActivityCenter.shared.micInUse = inUse
        }
        let next = Microphone(inUse: inUse, recorders: recorders)
        if next != microphone { microphone = next }
    }

    /// Whether the microphone is in use, from what can be known about it.
    ///
    /// Who is recording, where macOS will say: from 14.2 on, process by process, and nothing
    /// else is the answer there. `kAudioDevicePropertyDeviceIsRunningSomewhere` is a property of
    /// the whole device, and AirPods and most USB headsets are one device for both directions,
    /// so it read as running — the orange dot lit, a microphone "in use" — for as long as the
    /// headset played music. A call started on that headset then changed nothing the call card
    /// was watching, and so did not get one, and "Only during calls" did not hide the island
    /// from the screen share.
    ///
    /// Without the list — on 14.0 and 14.1, or when it could not be read — the device's word is
    /// taken only from a device with nothing to play: a microphone that is only a microphone
    /// runs only while something records from it. A headset then reads as idle even during a
    /// call, which is the smaller mistake of the two: a dot missing where macOS draws its own,
    /// rather than a dot and a call card over every song.
    ///
    /// Pure, so the rule can be read back without a microphone.
    static func micInUse(deviceRunning: Bool, hasOutput: Bool, recorders: Set<String>?) -> Bool {
        if let recorders { return !recorders.isEmpty }
        return deviceRunning && !hasOutput
    }

    // MARK: CoreAudio helpers

    private func listen(_ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                        handler: @escaping () -> Void) -> Registration {
        listen(object, address: AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                           mElement: kAudioObjectPropertyElementMain),
               handler: handler)
    }

    private func listen(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                        handler: @escaping () -> Void) -> Registration {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        _ = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        return Registration(object: object, address: address, block: block)
    }

    private func remove(_ registrations: inout [Registration]) {
        for var r in registrations {
            _ = AudioObjectRemovePropertyListenerBlock(r.object, &r.address, queue, r.block)
        }
        registrations.removeAll()
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }

    /// The bound device's level, asked for the same way and in the same order as everywhere
    /// else in this type.
    private func readVolume() -> Float32? { Self.readOutputVolume(device: outputDevice) }

    private func readMute() -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(outputDevice, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(outputDevice, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func readRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// Whether a device has anything to play through. One with no output streams is a
    /// microphone and nothing else. A device that will not say is taken as having none, which is
    /// the answer this gave for every device before it asked.
    private static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    // MARK: Who is recording (macOS 14.2 and later)

    /// Every process Core Audio has an object for, or nil when the list could not be read.
    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        let each = MemoryLayout<AudioObjectID>.stride
        var processes = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / each)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }
        // The list can shrink between asking its size and reading it.
        return Array(processes.prefix(Int(size) / each))
    }

    /// Every process Core Audio says is taking input, by bundle identifier, or nil when the list
    /// itself could not be read.
    ///
    /// A process with no bundle — `ffmpeg`, `sox`, a script — is named by its pid: it has the
    /// microphone all the same, and no call app will ever be mistaken for it. The island's own
    /// process is left out. The visualizer's tap of what is playing is input as far as Core
    /// Audio is concerned, and counting it would light the microphone for every song again.
    @available(macOS 14.2, *)
    private static func recordingProcesses() -> [String]? {
        guard let processes = processObjects() else { return nil }
        let island = getpid()
        return processes.compactMap { process -> String? in
            guard isRunningInput(process) else { return nil }
            let owner = pid(of: process)
            if owner == island { return nil }
            return bundleID(of: process) ?? owner.map { "pid \($0)" } ?? "process \(process)"
        }
    }

    @available(macOS 14.2, *)
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    @available(macOS 14.2, *)
    private static func pid(of process: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        return pid
    }

    @available(macOS 14.2, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &id) { pointer -> OSStatus in
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let id else { return nil }
        let value = id.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    // MARK: Direct control

    /// Volume of the default output device, 0...1, or nil when it has no volume control.
    /// The device is resolved on every call, so this also works before `start()`.
    func currentVolume() -> Float32? { AudioMonitor.readOutputVolume() }

    /// Mute state of the default output device, or nil when it cannot be muted.
    func isMuted() -> Bool? { AudioMonitor.readOutputMute() }

    /// Sets the volume of the default output device. Returns false when the write failed.
    @discardableResult
    func setVolume(_ level: Float32) -> Bool { AudioMonitor.writeOutputVolume(level) }

    /// Mutes / unmutes the default output device. Returns false when the write failed.
    @discardableResult
    func setMuted(_ muted: Bool) -> Bool { AudioMonitor.writeOutputMute(muted) }

    // MARK: Static device access (used by the media-key interceptor)

    /// The current default output device, or 0 when there is none.
    static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }

    /// Where an output's level can live: the virtual main volume the HAL synthesises on the
    /// main element, then the per-channel scalars that aggregate and USB devices use instead.
    ///
    /// One list, asked in one order, by everything that reads, writes, listens or merely
    /// wonders whether there is a level here at all. When the reader looked at two of these
    /// and the question "has this a level?" looked at three, a device that kept its level on
    /// the second channel was called settable and then never read — and the key died holding
    /// both answers.
    ///
    /// Listeners are registered for all of it and never for a chosen subset. Choosing means
    /// asking the device which properties it has at the moment it is bound, and a device that
    /// becomes the default before coreaudiod has finished publishing its volume answers
    /// "none" — after which its id never changes again and nothing is ever watched. The
    /// registrations that miss simply fail; the ones that land cost nothing extra, because
    /// every listener here reads the level and says nothing unless it has really moved.
    static let volumeElements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain] + volumeChannelElements

    /// The channels, on a device that has no synthesised main volume. Named separately
    /// because writing is not "the first one that takes it": a stereo device needs the value
    /// on both channels, where the main element sets the device outright.
    static let volumeChannelElements: [AudioObjectPropertyElement] = [1, 2]

    static func readOutputVolume() -> Float32? { readOutputVolume(device: defaultOutputDevice()) }

    static func readOutputVolume(device: AudioDeviceID) -> Float32? {
        guard device != 0 else { return nil }
        for element in volumeElements {
            if let v = scalarVolume(device: device, element: element) { return v }
        }
        return nil
    }

    @discardableResult
    static func writeOutputVolume(_ level: Float32) -> Bool {
        writeOutputVolume(level, device: defaultOutputDevice())
    }

    @discardableResult
    static func writeOutputVolume(_ level: Float32, device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        let value = max(0, min(1, level))
        if setScalarVolume(value, device: device, element: kAudioObjectPropertyElementMain) { return true }
        var ok = false
        for channel in volumeChannelElements {
            if setScalarVolume(value, device: device, element: channel) { ok = true }
        }
        if !ok { IslandLog.audio.error("could not set the volume on output \(device, privacy: .public)") }
        return ok
    }

    static func outputHasVolumeControl() -> Bool { outputHasVolumeControl(device: defaultOutputDevice()) }

    /// Whether the Mac can set this output's level at all.
    ///
    /// Asked about the same property, on the same elements, that `writeOutputVolume` writes:
    /// the virtual main volume on the main element, the per-channel scalar on the channels.
    /// Asking for the virtual one on a channel always answers no, because the HAL only
    /// synthesises it on the main element — which is why this belongs here, beside the
    /// address it shares, rather than anywhere that has to guess at it.

    static func outputHasVolumeControl(device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        for element in volumeElements {
            var address = volumeAddress(element: element)
            // Settable, not merely present. A level that can be read and not written is a key
            // that would be swallowed into a bar that never moves — and the message written
            // for exactly that case is guarded on this answer, so it would never be reached.
            if isSettable(device: device, address: &address) { return true }
        }
        return false
    }

    /// Whether this output has a mute the Mac can set. Its own question: a USB DAC can have a
    /// level and no mute at all, and answering for it out of the volume's answer swallows the
    /// mute key into silence.
    static func outputHasMuteControl(device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        return isSettable(device: device, address: &address)
    }

    static func readOutputMute() -> Bool? { readOutputMute(device: defaultOutputDevice()) }

    static func readOutputMute(device: AudioDeviceID) -> Bool? {
        guard device != 0 else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    static func writeOutputMute(_ muted: Bool) -> Bool { writeOutputMute(muted, device: defaultOutputDevice()) }

    @discardableResult
    static func writeOutputMute(_ muted: Bool, device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard isSettable(device: device, address: &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            IslandLog.audio.error("could not set mute on output \(device, privacy: .public) (status \(status, privacy: .public))")
        }
        return status == noErr
    }

    static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        let selector: AudioObjectPropertySelector = element == kAudioObjectPropertyElementMain
            ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume
            : kAudioDevicePropertyVolumeScalar
        return AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: kAudioDevicePropertyScopeOutput,
                                          mElement: element)
    }

    private static func scalarVolume(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setScalarVolume(_ value: Float32, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = volumeAddress(element: element)
        guard isSettable(device: device, address: &address) else { return false }
        var v = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    private static func isSettable(device: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }
}
