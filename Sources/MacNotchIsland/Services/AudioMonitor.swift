import Foundation
import CoreAudio
import AudioToolbox

/// Watches the default output device (volume HUD, silent-mode alert) and the default
/// input device (microphone-in-use privacy indicator) through CoreAudio property listeners.
final class AudioMonitor {
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var systemRegistrations: [Registration] = []
    private var outputRegistrations: [Registration] = []
    private var inputRegistrations: [Registration] = []
    private var outputDevice: AudioDeviceID = 0
    private var inputDevice: AudioDeviceID = 0
    private var lastVolume: Float32 = -1
    private var lastMute: Bool?
    private var running = false
    private let queue = DispatchQueue.main

    var onMicrophoneChange: ((Bool) -> Void)?

    func start() {
        guard !running else { return }
        running = true
        systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject),
                                          selector: kAudioHardwarePropertyDefaultOutputDevice,
                                          scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.bindOutput() })
        systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject),
                                          selector: kAudioHardwarePropertyDefaultInputDevice,
                                          scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.bindInput() })
        bindOutput()
        bindInput()
    }

    func stop() {
        guard running else { return }
        running = false
        remove(&systemRegistrations)
        remove(&outputRegistrations)
        remove(&inputRegistrations)
        ActivityCenter.shared.micInUse = false
    }

    // MARK: Binding

    private func bindOutput() {
        remove(&outputRegistrations)
        outputDevice = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        guard outputDevice != 0 else { return }
        lastVolume = readVolume() ?? -1
        lastMute = readMute()
        // Wherever this device's level actually is, not just the synthesised main one: an
        // aggregate or USB device that keeps it on a channel would otherwise never report a
        // change, while the media-key path showed one — two behaviours for one device.
        for element in Self.volumeElements(on: outputDevice) {
            outputRegistrations.append(listen(outputDevice, address: Self.volumeAddress(element: element)) {
                [weak self] in self?.volumeChanged()
            })
        }
        outputRegistrations.append(listen(outputDevice, selector: kAudioDevicePropertyMute,
                                          scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.muteChanged() })
    }

    private func bindInput() {
        remove(&inputRegistrations)
        inputDevice = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        guard inputDevice != 0 else { return }
        inputRegistrations.append(listen(inputDevice, selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                         scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.microphoneChanged() })
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
        let running = readRunningSomewhere(inputDevice)
        if ActivityCenter.shared.micInUse != running {
            ActivityCenter.shared.micInUse = running
        }
        onMicrophoneChange?(running)
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
    /// One list, asked in one order, by everything that reads, writes or merely wonders
    /// whether there is a level here at all. When the reader looked at two of these and the
    /// question "has this a level?" looked at three, a device that kept its level on the
    /// second channel was called settable and then never read — and the key died holding
    /// both answers.
    static let volumeElements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain] + volumeChannelElements

    /// The channels, on a device that has no synthesised main volume. Named separately
    /// because writing is not "the first one that takes it": a stereo device needs the value
    /// on both channels, where the main element sets the device outright.
    static let volumeChannelElements: [AudioObjectPropertyElement] = [1, 2]

    static func readOutputVolume() -> Float32? { readOutputVolume(device: defaultOutputDevice()) }

    /// Marks a write as the island's own, so the listener does not announce a change the
    /// island has already answered for itself. See `LocalWrite`.
    static func markLocalWrite() { AudioOutputs.markLocalWrite() }

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
        if !ok { NSLog("Notch Island: could not set the output volume on device \(device).") }
        return ok
    }

    /// Whether the Mac can set the default output's level at all.
    ///
    /// Asked about the same property, on the same elements, that `writeOutputVolume` writes:
    /// the virtual main volume on the main element, the per-channel scalar on the channels.
    /// Asking for the virtual one on a channel always answers no, because the HAL only
    /// synthesises it on the main element — which is why this belongs here, beside the
    /// address it shares, rather than anywhere that has to guess at it.
    /// Where this device's level actually lives.
    ///
    /// The synthesised main volume if it has one — that is the whole device in a single
    /// property — and only otherwise the channels it keeps it on instead. A stereo device has
    /// all three, and watching all three would report one notch of the volume key three times.
    static func volumeElements(on device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        guard device != 0 else { return [] }
        var main = volumeAddress(element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) { return [kAudioObjectPropertyElementMain] }
        return volumeChannelElements.filter { element in
            var address = volumeAddress(element: element)
            return AudioObjectHasProperty(device, &address)
        }
    }

    static func outputHasVolumeControl() -> Bool { outputHasVolumeControl(device: defaultOutputDevice()) }

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
        if status != noErr { NSLog("Notch Island: could not set mute on device \(device) (status \(status)).") }
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
