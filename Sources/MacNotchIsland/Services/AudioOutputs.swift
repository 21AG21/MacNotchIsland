import AudioToolbox
import Combine
import CoreAudio
import Foundation

extension LevelHUD {
    /// A volume HUD that also says which output it is for.
    ///
    /// Named only when it is not the Mac's own speakers: pointing at the built-in speakers
    /// every time you touch the volume is clutter, and pointing at the AirPods is the whole
    /// point — it is the answer to "why is nothing getting louder".
    static func volume(level: Double, isMuted: Bool, output: AudioOutputs.Device?) -> LevelHUD {
        var hud = LevelHUD(kind: .volume, level: level, isMuted: isMuted)
        guard let output, output.transport != kAudioDeviceTransportTypeBuiltIn else { return hud }
        hud.device = output.shortName
        hud.deviceSymbol = output.symbol
        return hud
    }

    /// The answer for an output the Mac cannot set the level of: it says so, and says which
    /// output, which is more than the key press would otherwise have produced.
    static func unavailableVolume(output: AudioOutputs.Device?) -> LevelHUD {
        var hud = LevelHUD(kind: .volume, level: 0)
        hud.isUnavailable = true
        hud.device = output?.shortName
        hud.deviceSymbol = output?.symbol
        return hud
    }
}

/// The sound output as the Now Playing card needs it: which device is playing, which others
/// could, and the system volume, all live. CoreAudio listeners run only while a view shows
/// them; picking a device or moving the slider writes straight back to CoreAudio, the same
/// way the Sound menu bar item does.
final class AudioOutputs: ObservableObject {
    static let shared = AudioOutputs()

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32

        /// The glyph the Sound menu would use for this kind of device.
        var symbol: String {
            let lower = name.lowercased()
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            if lower.contains("beats") { return "beats.headphones" }
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
            case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI: return "hifispeaker"
            default: return "speaker.wave.2"
            }
        }

        /// "MacBook Air Speakers" reads better as just "MacBook Air" beside its glyph.
        var shortName: String {
            name.replacingOccurrences(of: " Speakers", with: "")
        }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var current: Device?
    /// 0...1, or nil when the device has no volume control (HDMI, some AirPlay targets).
    @Published private(set) var volume: Float?
    @Published private(set) var isMuted = false

    private var viewers = 0
    private var systemRegistrations: [Registration] = []
    private var deviceRegistrations: [Registration] = []
    private var boundDevice: AudioDeviceID = 0
    private let queue = DispatchQueue.main

    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private init() {}

    // MARK: - Lifetime

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices,
                                          scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.reloadDevices() })
        systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice,
                                          scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.reloadDevices() })
        reloadDevices()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        remove(&systemRegistrations)
        remove(&deviceRegistrations)
        boundDevice = 0
    }

    // MARK: - Reading

    func reloadDevices() {
        let ids = Self.allDeviceIDs().filter { Self.outputStreamCount($0) > 0 }
        let list = ids.map { Device(id: $0, name: Self.name(of: $0), transport: Self.transport(of: $0)) }
            .sorted { a, b in
                if (a.transport == kAudioDeviceTransportTypeBuiltIn) != (b.transport == kAudioDeviceTransportTypeBuiltIn) {
                    return a.transport == kAudioDeviceTransportTypeBuiltIn
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        if list != devices { devices = list }
        let defaultID = AudioMonitor.defaultOutputDevice()
        let now = list.first { $0.id == defaultID }
        if now != current { current = now }
        if boundDevice != defaultID {
            remove(&deviceRegistrations)
            boundDevice = defaultID
            if defaultID != 0 {
                deviceRegistrations.append(listen(defaultID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                  scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.reloadLevel() })
                deviceRegistrations.append(listen(defaultID, selector: kAudioDevicePropertyMute,
                                                  scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.reloadLevel() })
            }
        }
        reloadLevel()
    }

    private func reloadLevel() {
        let v = AudioMonitor.readOutputVolume()
        if v != volume { volume = v }
        let m = AudioMonitor.readOutputMute() ?? false
        if m != isMuted { isMuted = m }
    }

    // MARK: - Writing

    func select(_ device: Device) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr { IslandLog.island.error("could not select output \(device.name, privacy: .public): \(status, privacy: .public)") }
        reloadDevices()
    }

    func setVolume(_ level: Float) {
        let clamped = max(0, min(1, level))
        if AudioMonitor.writeOutputVolume(clamped) {
            volume = clamped
            if clamped > 0, isMuted, AudioMonitor.writeOutputMute(false) { isMuted = false }
        }
    }

    func setMuted(_ muted: Bool) {
        if AudioMonitor.writeOutputMute(muted) { isMuted = muted }
    }

    // MARK: - CoreAudio

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

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func outputStreamCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// The output the Mac is playing through right now, read straight from CoreAudio.
    ///
    /// The published `current` only exists while a view is watching, and the volume HUD fires
    /// whether or not one is; this asks the two questions it needs and nothing else.
    static func currentOutput() -> Device? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return Device(id: id, name: name(of: id), transport: transport(of: id))
    }

    /// Whether the Mac can set this device's level at all. HDMI and some AirPlay targets
    /// simply carry the sound at whatever the thing at the other end is set to, and asking
    /// for the level returns nothing — which is a different thing from a read that failed.
    static func hasVolumeControl(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(device, &address)
    }

    private static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let name = value?.takeRetainedValue() else {
            return "Output"
        }
        return name as String
    }

    private static func transport(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
}
