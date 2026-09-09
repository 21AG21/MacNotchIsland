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
        outputRegistrations.append(listen(outputDevice, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                          scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.volumeChanged() })
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
        // Only once the island has actually taken the media keys over. Otherwise macOS is
        // already drawing its bezel for this, and a second one beside it is pure noise.
        guard Preferences.shared.volumeHUDEnabled, SystemHUDReplacement.shared.isActive,
              !AudioOutputs.wroteRecently(), let v = readVolume() else { return }
        let muted = readMute() ?? false
        guard abs(v - lastVolume) > 0.001 else { return }
        lastVolume = v
        let hud = LevelHUD.volume(level: Double(v), isMuted: muted, output: AudioOutputs.currentOutput())
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85), duration: 1.5, haptic: false)
    }

    private func muteChanged() {
        guard Preferences.shared.volumeHUDEnabled, SystemHUDReplacement.shared.isActive,
              let muted = readMute() else { return }
        guard muted != lastMute else { return }
        lastMute = muted
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
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
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

    private func readVolume() -> Float32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(outputDevice, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(outputDevice, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

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

    static func readOutputVolume() -> Float32? {
        let device = defaultOutputDevice()
        guard device != 0 else { return nil }
        if let v = scalarVolume(device: device, element: kAudioObjectPropertyElementMain) { return v }
        // Some aggregate / USB devices only expose per-channel volume.
        return scalarVolume(device: device, element: 1)
    }

    @discardableResult
    static func writeOutputVolume(_ level: Float32) -> Bool {
        let device = defaultOutputDevice()
        guard device != 0 else { return false }
        let value = max(0, min(1, level))
        if setScalarVolume(value, device: device, element: kAudioObjectPropertyElementMain) { return true }
        var ok = false
        for channel in UInt32(1)...UInt32(2) {
            if setScalarVolume(value, device: device, element: channel) { ok = true }
        }
        if !ok { NSLog("Notch Island: could not set the output volume on device \(device).") }
        return ok
    }

    static func readOutputMute() -> Bool? {
        let device = defaultOutputDevice()
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
    static func writeOutputMute(_ muted: Bool) -> Bool {
        let device = defaultOutputDevice()
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

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
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
