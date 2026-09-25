import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Mutes the microphone for every app at once: the default input device itself, not one app's
/// idea of it.
///
/// Control Centre's Mic Mode module chooses how the microphone sounds and never whether it is
/// on; the only mute macOS offers is inside whichever call app is running, which is three
/// different buttons in three different places across a day of calls — and none of them
/// covers the app that picked up the microphone without asking. This throws the switch on the
/// device, the one every app is listening through.
///
/// Not every microphone has a switch. A device that says its mute cannot be set is silenced by
/// turning its input level down to nothing instead, and the level it had is put back on
/// unmute — see `route(muteSettable:volumeSettable:)`, which is the decision on its own.
///
/// Event-driven and lazy: nothing is watched until something first asks for `shared`, and from
/// then on CoreAudio says when the default input changes or when somebody else mutes or
/// unmutes, so `isMuted` is the system's answer rather than a memory of the last click. No
/// timer. Main thread only.
final class MicrophoneControl: ObservableObject {
    static let shared = MicrophoneControl()

    /// Whether the default input device is silent right now, whoever silenced it.
    @Published private(set) var isMuted = false
    /// Whether there is a microphone the island can mute at all: a default input device with
    /// either a mute of its own or an input level to turn down.
    @Published private(set) var isAvailable = false

    /// How a microphone is silenced.
    enum Route: Equatable {
        /// The device's own mute: `kAudioDevicePropertyMute`, input scope, main element.
        case mute
        /// No mute to throw, so the input level goes to zero and comes back on unmute.
        case volume
        /// Neither can be set. Nothing the island does would reach it.
        case unavailable
    }

    /// The decision on its own: the device's mute where it has one the Mac may set, its input
    /// level where it has only that, and nothing where it has neither.
    ///
    /// The mute first, always. A level set to zero is a mute that forgets where it was: it is
    /// what the slider in the Sound pane shows, it is what a call app's own level meter reads
    /// back, and somebody who drags it up again elsewhere has undone it without knowing. It is
    /// the fallback because it is the only thing some USB interfaces offer.
    static func route(muteSettable: Bool, volumeSettable: Bool) -> Route {
        if muteSettable { return .mute }
        if volumeSettable { return .volume }
        return .unavailable
    }

    /// Whether a device reads as muted, from what it reports along the route it is muted by. A
    /// device silenced by its level counts as muted while that level is nothing, which is the
    /// truth about it whether the island turned it down or somebody else did.
    static func isMuted(route: Route, mute: Bool?, level: Float32?) -> Bool {
        switch route {
        case .mute: return mute ?? false
        case .volume: return (level ?? 1) <= silence
        case .unavailable: return false
        }
    }

    /// The level put back on a microphone muted by its level: the one it had, or — where that
    /// was never seen, because it was already at nothing when the island first met it — a
    /// level that is plainly on without being the top of the scale.
    static func restoredLevel(saved: Float32?) -> Float32 {
        guard let saved, saved.isFinite, saved > silence else { return defaultLevel }
        return min(1, saved)
    }

    /// At or below this an input level is silence.
    static let silence: Float32 = 0.001
    /// What an unmuted microphone comes back at when its own level is not known.
    static let defaultLevel: Float32 = 0.75

    /// The island's own mute, kept by device: every microphone it has silenced and not yet
    /// given back.
    ///
    /// A new default microphone — the AirPods connecting halfway through a call — inherits the
    /// mute, because somebody who pressed mute did not mean "until the headphones change". It
    /// used to be one Bool, which knew that a mute was in force and not where: unmuting reached
    /// only the microphone in use by then, and the one the mute had been carried from stayed
    /// silent, to be found muted again the moment the AirPods went. Now every microphone the
    /// mute was put on is remembered by UID, which outlives the device's numeric id, and each is
    /// given back when it ends.
    struct HeldMute: Equatable {
        /// UIDs, in the order the mute reached them.
        private(set) var devices: [String] = []
        /// Microphones the mute was on when it ended, that were not there to be given back: the
        /// AirPods that inherited it and went before the unmute. CoreAudio keeps a mute with
        /// the device, and they came back still muted with nothing left to say so. Each is
        /// owed its unmute until it is next seen (`reappeared`).
        private(set) var owed: [String] = []

        /// Whether the island's mute is in force, which is whether a new microphone inherits it.
        var isHeld: Bool { !devices.isEmpty }

        /// The mute has reached this microphone: the island muted it, or found it already silent
        /// when it became the one in use. Whatever it was owed is settled by that.
        mutating func muted(_ uid: String) {
            if !devices.contains(uid) { devices.append(uid) }
            owed.removeAll { $0 == uid }
        }

        /// These were not connected to be given back when the mute ended; they are owed it.
        mutating func unreachable(_ uids: [String]) {
            for uid in uids where !owed.contains(uid) { owed.append(uid) }
        }

        /// A microphone owed an unmute is connected again. Whether to unmute it now: yes while
        /// no mute is in force. With one in force it stays silent and is under that mute now,
        /// to be given back when it ends — the mute it had was carried, and it still stands.
        mutating func reappeared(_ uid: String) -> Bool {
            guard owed.contains(uid) else { return false }
            owed.removeAll { $0 == uid }
            if isHeld {
                muted(uid)
                return false
            }
            return true
        }

        /// Whether the microphone in use reading unmuted ends the mute: only if the mute is on
        /// it. One the mute could not reach — a USB microphone with neither a mute nor a level —
        /// was never silenced, and its being live ends nothing: the mute is still on the
        /// microphone it was left on, and comes back with it.
        func endsWhenUnmuted(_ uid: String?) -> Bool {
            guard let uid else { return false }
            return devices.contains(uid)
        }

        /// The mute is over — unmuted from the island, or from anywhere on the microphone in use.
        /// Forgets every device and returns the ones to unmute: all of them but `current`, which
        /// whoever ended the mute has already dealt with.
        mutating func release(except current: String?) -> [String] {
            defer { devices.removeAll() }
            return devices.filter { $0 != current }
        }
    }

    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var systemRegistration: Registration?
    /// The list of devices, heard so a microphone owed its unmute is given it when it comes
    /// back, whether or not it comes back as the one in use.
    private var devicesRegistration: Registration?
    private var deviceRegistrations: [Registration] = []
    private var device = AudioDeviceID(0)
    /// The mute the island put there, and every microphone it is on. Released the moment the
    /// microphone in use reads unmuted, whoever unmuted it.
    private var held = HeldMute()
    private let queue = DispatchQueue.main
    /// Levels saved before a mute by level, per device UID, kept across relaunches so that a
    /// microphone muted yesterday still comes back where it was.
    private static let savedLevelsKey = "microphoneLevelsBeforeMute"

    private init() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        systemRegistration = listen(AudioObjectID(kAudioObjectSystemObject), address: &address) { [weak self] in
            self?.bind()
        }
        var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        devicesRegistration = listen(AudioObjectID(kAudioObjectSystemObject), address: &devices) { [weak self] in
            self?.bind()
        }
        bind()
    }

    // MARK: - Switching

    func toggle() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        // The default may have changed since the last notification landed.
        bind()
        guard device != 0 else {
            IslandLog.audio.notice("no microphone to \(muted ? "mute" : "unmute", privacy: .public)")
            return
        }
        if write(muted, to: device) {
            if muted {
                if let uid = Self.uid(of: device) { held.muted(uid) }
            } else {
                giveBack(held.release(except: Self.uid(of: device)))
            }
        } else {
            IslandLog.audio.error("could not \(muted ? "mute" : "unmute", privacy: .public) input \(self.device, privacy: .public)")
        }
        reload()
    }

    /// Silences or restores one device along whichever route it offers.
    private func write(_ muted: Bool, to device: AudioDeviceID) -> Bool {
        switch Self.route(for: device) {
        case .mute:
            return Self.writeMute(muted, device: device)
        case .volume:
            if muted {
                // Only a level that is on is worth remembering: muting twice must not save the
                // silence the first mute left behind.
                if let level = Self.readLevel(device: device), level > Self.silence {
                    Self.saveLevel(level, device: device)
                }
                return Self.writeLevel(0, device: device)
            }
            let level = Self.restoredLevel(saved: Self.savedLevel(device: device))
            let ok = Self.writeLevel(level, device: device)
            if ok { Self.saveLevel(nil, device: device) }
            return ok
        case .unavailable:
            return false
        }
    }

    // MARK: - Following the system

    /// Watches the default input device, and moves the watching when the default changes.
    private func bind() {
        settleOwed()
        let next = AudioOutputs.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        guard next != device else { return reload() }
        let carry = held.isHeld
        remove(&deviceRegistrations)
        device = next
        if next != 0 {
            var mute = Self.muteAddress
            deviceRegistrations.append(listen(next, address: &mute) { [weak self] in self?.reload() })
            for element in Self.levelElements {
                var level = Self.levelAddress(element: element)
                deviceRegistrations.append(listen(next, address: &level) { [weak self] in self?.reload() })
            }
            if carry {
                if Self.readsMuted(next) || write(true, to: next) {
                    if let uid = Self.uid(of: next) { held.muted(uid) }
                } else {
                    IslandLog.audio.error("the new microphone \(next, privacy: .public) could not be muted")
                }
            }
        }
        reload()
    }

    private func reload() {
        let route = device == 0 ? Route.unavailable : Self.route(for: device)
        let available = route != .unavailable
        let muted = device != 0 && Self.readsMuted(device, route: route)
        // Somebody unmuted it — the Sound pane, the call app, a key on the headset. The
        // island's mute is over: a later change of device must not bring it back, and the
        // microphones it was carried from are given back too. Not on no device at all, which
        // is only the moment between one default and the next.
        if device != 0, !muted, held.isHeld, let uid = Self.uid(of: device), held.endsWhenUnmuted(uid) {
            giveBack(held.release(except: uid))
        }
        if available != isAvailable { isAvailable = available }
        if muted != isMuted { isMuted = muted }
    }

    /// Unmutes microphones the island muted and has since moved on from. Only the ones still
    /// silent: one somebody has turned back on is left as it is. One that has gone cannot be
    /// reached now, and is owed its unmute for when it is back (`settleOwed`).
    private func giveBack(_ uids: [String]) {
        var away: [String] = []
        for uid in uids {
            guard let other = Self.connectedDevice(uid: uid) else {
                away.append(uid)
                continue
            }
            guard other != device, Self.readsMuted(other) else { continue }
            if !write(false, to: other) {
                IslandLog.audio.error("could not give back the microphone \(other, privacy: .public)")
            }
        }
        held.unreachable(away)
    }

    /// Gives a microphone owed its unmute (`HeldMute.reappeared`) that unmute, now that it is
    /// connected again and no mute is in force — before the default is looked at, so a mute
    /// in force that it arrives into is carried to it as to any other.
    private func settleOwed() {
        for uid in held.owed {
            guard let back = Self.connectedDevice(uid: uid), held.reappeared(uid) else { continue }
            guard Self.readsMuted(back) else { continue }
            if !write(false, to: back) {
                IslandLog.audio.error("could not give back the microphone \(back, privacy: .public)")
            }
        }
    }

    // MARK: - CoreAudio

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Where an input level can live: the main element, then the first two channels, for the
    /// devices that keep a level per channel and none for the whole — the same list, in the
    /// same order, `AudioMonitor` uses for outputs.
    private static let levelElements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    private static func levelAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeInput,
                                   mElement: element)
    }

    private static func route(for device: AudioDeviceID) -> Route {
        var mute = muteAddress
        let levelSettable = levelElements.contains { element in
            var address = levelAddress(element: element)
            return isSettable(device, &address)
        }
        return route(muteSettable: isSettable(device, &mute), volumeSettable: levelSettable)
    }

    private static func readsMuted(_ device: AudioDeviceID) -> Bool {
        readsMuted(device, route: route(for: device))
    }

    private static func readsMuted(_ device: AudioDeviceID, route: Route) -> Bool {
        switch route {
        case .mute: return isMuted(route: route, mute: readMute(device: device), level: nil)
        case .volume: return isMuted(route: route, mute: nil, level: readLevel(device: device))
        case .unavailable: return false
        }
    }

    private static func readMute(device: AudioDeviceID) -> Bool? {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func writeMute(_ muted: Bool, device: AudioDeviceID) -> Bool {
        var address = muteAddress
        guard isSettable(device, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            IslandLog.audio.error("input mute refused on \(device, privacy: .public) (status \(status, privacy: .public))")
        }
        return status == noErr
    }

    /// The input level, from the first element that has one.
    private static func readLevel(device: AudioDeviceID) -> Float32? {
        for element in levelElements {
            var address = levelAddress(element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    /// The main element where it can be set, otherwise every channel that can: a stereo
    /// interface left with one channel live is not muted.
    private static func writeLevel(_ level: Float32, device: AudioDeviceID) -> Bool {
        let value = max(0, min(1, level))
        var main = levelAddress(element: kAudioObjectPropertyElementMain)
        if isSettable(device, &main) { return setLevel(value, device: device, address: &main) }
        var ok = false
        for element in levelElements where element != kAudioObjectPropertyElementMain {
            var address = levelAddress(element: element)
            if isSettable(device, &address), setLevel(value, device: device, address: &address) { ok = true }
        }
        return ok
    }

    private static func setLevel(_ value: Float32, device: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        var v = value
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if status != noErr {
            IslandLog.audio.error("input level refused on \(device, privacy: .public) (status \(status, privacy: .public))")
        }
        return status == noErr
    }

    private static func isSettable(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard device != 0, AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private func listen(_ object: AudioObjectID, address: inout AudioObjectPropertyAddress,
                        handler: @escaping () -> Void) -> Registration {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status != noErr {
            // A device without that property refuses the listener, and that is expected.
            let selector = address.mSelector
            IslandLog.audio.debug("no listener for \(selector, privacy: .public) on \(object, privacy: .public)")
        }
        return Registration(object: object, address: address, block: block)
    }

    private func remove(_ registrations: inout [Registration]) {
        for var r in registrations {
            _ = AudioObjectRemovePropertyListenerBlock(r.object, &r.address, queue, r.block)
        }
        registrations.removeAll()
    }

    // MARK: - The level before a mute by level

    /// A device's UID, which outlives its numeric id: the id is handed out afresh every time
    /// the device appears, the UID is the device.
    private static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let uid else { return nil }
        let value = uid.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    /// The device a UID names right now, or nil when it is not connected.
    private static func connectedDevice(uid: String) -> AudioDeviceID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let each = MemoryLayout<AudioDeviceID>.stride
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / each)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.prefix(Int(size) / each).first { Self.uid(of: $0) == uid }
    }

    private static func savedLevel(device: AudioDeviceID) -> Float32? {
        guard let uid = uid(of: device),
              let levels = UserDefaults.standard.dictionary(forKey: savedLevelsKey),
              let level = levels[uid] as? Double else { return nil }
        return Float32(level)
    }

    /// Nil forgets the device's saved level.
    private static func saveLevel(_ level: Float32?, device: AudioDeviceID) {
        guard let uid = uid(of: device) else { return }
        var levels = UserDefaults.standard.dictionary(forKey: savedLevelsKey) ?? [:]
        if let level {
            levels[uid] = Double(level)
        } else {
            levels.removeValue(forKey: uid)
        }
        UserDefaults.standard.set(levels, forKey: savedLevelsKey)
    }
}
