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
        guard Preferences.shared.volumeHUDEnabled, let v = readVolume() else { return }
        let muted = readMute() ?? false
        guard abs(v - lastVolume) > 0.001 else { return }
        lastVolume = v
        let hud = LevelHUD(kind: .volume, level: Double(v), isMuted: muted)
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85), duration: 1.5, haptic: false)
    }

    private func muteChanged() {
        guard Preferences.shared.volumeHUDEnabled, let muted = readMute() else { return }
        guard muted != lastMute else { return }
        lastMute = muted
        let activity = IslandActivity(id: "silent", kind: .silent, content: .silent(SilentState(isSilent: muted)), priority: 85)
        ActivityCenter.shared.showAlert(activity, duration: 2)
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
}
