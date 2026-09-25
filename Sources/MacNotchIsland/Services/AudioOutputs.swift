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
    /// Where the sound comes *from*: the other half of Control Centre's Sound module, and the
    /// half nobody can reach without opening System Settings.
    @Published private(set) var inputs: [Device] = []
    @Published private(set) var currentInput: Device?
    /// 0...1, or nil when the device has no volume control (HDMI, some AirPlay targets).
    @Published private(set) var volume: Float?
    @Published private(set) var isMuted = false
    /// Whether this output has a mute of its own. Some do not, and offering a switch that
    /// cannot move is worse than offering none.
    @Published private(set) var hasMute = false

    /// One AirPlay receiver — a HomePod, an Apple TV, a speaker — as the AirPlay device lists
    /// it: one of that device's data sources, by the id CoreAudio gave it and the name it
    /// answered with.
    struct AirPlayTarget: Identifiable, Equatable {
        let device: AudioDeviceID
        let source: UInt32
        let name: String
        var id: String { "\(device)-\(source)" }
    }

    /// The receivers the AirPlay device offers, as `AirPlayList.targets` lets them through.
    /// Empty where the device lists none, which on a current macOS may be always: whether the
    /// AirPlay device still carries its receivers as data sources is not written down anywhere,
    /// which is why the Sound column also keeps the system's own route picker.
    @Published private(set) var airPlay: [AirPlayTarget] = []
    /// The receivers the sound is going to: the AirPlay device's selected data sources, and
    /// only while it is the output.
    @Published private(set) var airPlayCurrent: Set<UInt32> = []

    /// Whether there is anywhere else the sound could go: the outputs the picker lists and the
    /// AirPlay receivers, more than one between them.
    var hasChoice: Bool { AirPlayList.hasChoice(outputs: devices, airPlay: airPlay) }

    /// The outputs as the picker lists them. See `AirPlayList.outputs`.
    var shownOutputs: [Device] { AirPlayList.outputs(devices, airPlay: airPlay) }

    /// Where the sound is going, by name: the AirPlay receivers it is on, or else the output.
    var destinationName: String? {
        let receivers = airPlay.filter { airPlayCurrent.contains($0.source) }.map(\.name)
        return receivers.isEmpty ? current?.name : receivers.joined(separator: ", ")
    }

    private var viewers = 0
    private var systemRegistrations: [Registration] = []
    private var deviceRegistrations: [Registration] = []
    private var boundDevice: AudioDeviceID = 0
    /// The AirPlay device's list of receivers and its choice among them, watched so a HomePod
    /// that wakes up joins the list without the panel being opened again.
    private var airPlayRegistrations: [Registration] = []
    private var boundAirPlay: AudioDeviceID = 0
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
        remove(&airPlayRegistrations)
        boundDevice = 0
        boundAirPlay = 0
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
        reloadInputs()
        let defaultID = AudioMonitor.defaultOutputDevice()
        let now = list.first { $0.id == defaultID }
        if now != current { current = now }
        if boundDevice != defaultID {
            remove(&deviceRegistrations)
            boundDevice = defaultID
            if defaultID != 0 {
                // Wherever this device might keep its level — see `AudioMonitor.volumeElements`.
                // Watching only the synthesised main one left the rail's slider frozen on a
                // device that has none, while the media keys moved it.
                for element in AudioMonitor.volumeElements {
                    deviceRegistrations.append(listen(defaultID, address: AudioMonitor.volumeAddress(element: element)) {
                        [weak self] in self?.reloadLevel()
                    })
                }
                deviceRegistrations.append(listen(defaultID, selector: kAudioDevicePropertyMute,
                                                  scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.reloadLevel() })
            }
        }
        reloadAirPlay(in: list, defaultOutput: defaultID)
        reloadLevel()
    }

    /// The AirPlay device's receivers, read as its data sources — the way the Sound pane listed
    /// AirPlay speakers when it listed them at all. Asked on every reload, which is every change
    /// to the device list and to the default output, and whenever the AirPlay device says its
    /// list or its choice has changed.
    private func reloadAirPlay(in list: [Device], defaultOutput: AudioDeviceID) {
        let device = list.first { $0.transport == kAudioDeviceTransportTypeAirPlay }
        // Watched only while something shows the list: a reload from a write with nothing on
        // screen must not leave listeners behind that nothing will take down.
        let watched = viewers > 0 ? (device?.id ?? 0) : 0
        if boundAirPlay != watched {
            remove(&airPlayRegistrations)
            boundAirPlay = watched
            if watched != 0 {
                for selector in [kAudioDevicePropertyDataSources, kAudioDevicePropertyDataSource] {
                    airPlayRegistrations.append(listen(watched, selector: selector, scope: kAudioDevicePropertyScopeOutput) {
                        [weak self] in self?.reloadDevices()
                    })
                }
            }
        }
        var targets: [AirPlayTarget] = []
        var ticked: Set<UInt32> = []
        if let device {
            let sources = (Self.dataSources(of: device.id) ?? []).map {
                AirPlayList.Source(id: $0, name: Self.dataSourceName($0, of: device.id))
            }
            targets = AirPlayList.targets(device: device.id, deviceName: device.name, sources: sources)
            if !targets.isEmpty {
                ticked = AirPlayList.ticked(selected: Self.selectedDataSources(of: device.id) ?? [],
                                            targets: targets, isDefaultOutput: device.id == defaultOutput)
            }
        }
        if targets != airPlay { airPlay = targets }
        if ticked != airPlayCurrent { airPlayCurrent = ticked }
    }

    /// The devices that can record, and which of them the Mac is listening to.
    private func reloadInputs() {
        let list = Self.allDeviceIDs()
            .filter { Self.inputStreamCount($0) > 0 }
            .map { Device(id: $0, name: Self.name(of: $0), transport: Self.transport(of: $0)) }
            .sorted { a, b in
                if (a.transport == kAudioDeviceTransportTypeBuiltIn) != (b.transport == kAudioDeviceTransportTypeBuiltIn) {
                    return a.transport == kAudioDeviceTransportTypeBuiltIn
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        if list != inputs { inputs = list }
        let defaultID = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let now = list.first { $0.id == defaultID }
        if now != currentInput { currentInput = now }
    }

    /// Which device a system-wide default points at.
    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return 0 }
        return device
    }

    /// Listens through this one instead. The same write the Sound pane makes.
    func selectInput(_ device: Device) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr {
            IslandLog.island.error("could not switch the input: \(status, privacy: .public)")
        }
        reloadInputs()
    }

    private func reloadLevel() {
        let v = AudioMonitor.readOutputVolume()
        if v != volume { volume = v }
        let m = AudioMonitor.readOutputMute()
        if (m != nil) != hasMute { hasMute = m != nil }
        if (m ?? false) != isMuted { isMuted = m ?? false }
    }

    // MARK: - The gallery

    /// Devices the drawing pass can show without a sound card. See `RenderMode.isGallery`.
    func seedForGallery(outputs: [Device], current: Device?, inputs: [Device], currentInput: Device?,
                        volume: Float?, isMuted: Bool) {
        devices = outputs
        self.current = current
        self.inputs = inputs
        self.currentInput = currentInput
        self.volume = volume
        self.isMuted = isMuted
        hasMute = !outputs.isEmpty
        airPlay = []
        airPlayCurrent = []
    }

    // MARK: - Writing

    func select(_ device: Device) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr { IslandLog.audio.error("could not select output \(device.name, privacy: .public): \(status, privacy: .public)") }
        reloadDevices()
    }

    /// Sends the sound to one AirPlay receiver: the AirPlay device becomes the output first, and
    /// then its data source is set to the receiver, which is the order the Sound pane did it in.
    /// Every step that CoreAudio refuses is logged by name, because how the AirPlay device
    /// answers this on a given macOS is not written down anywhere; a refusal leaves the output
    /// where it was, and the route picker under the list is still there to do it the system's way.
    func selectAirPlay(_ target: AirPlayTarget) {
        var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
        var id = target.device
        let madeDefault = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil,
                                                     UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        guard madeDefault == noErr else {
            IslandLog.audio.error("could not make AirPlay the output for \(target.name, privacy: .public): \(madeDefault, privacy: .public)")
            reloadDevices()
            return
        }
        var sourceAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                       mScope: kAudioDevicePropertyScopeOutput,
                                                       mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        let asked = AudioObjectIsPropertySettable(target.device, &sourceAddress, &settable)
        if asked != noErr || !settable.boolValue {
            // Tried anyway: a device that says no here has been known to take the write.
            IslandLog.audio.notice("the AirPlay device says its data source is not settable (\(asked, privacy: .public)); trying \(target.name, privacy: .public) anyway")
        }
        // The property is a list of the selected sources; a list of one is one UInt32.
        var source = target.source
        let status = AudioObjectSetPropertyData(target.device, &sourceAddress, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &source)
        if status != noErr {
            IslandLog.audio.error("could not send AirPlay to \(target.name, privacy: .public): \(status, privacy: .public)")
        }
        reloadDevices()
    }

    /// When the island last set the level itself, from its own slider. See `LocalWrite`.
    private(set) static var lastLocalWrite = LocalWrite.never

    /// Whether the island wrote the level itself a moment ago.
    static func wroteRecently(now: TimeInterval = LocalWrite.now()) -> Bool {
        LocalWrite.isRecent(lastLocalWrite, now: now)
    }

    /// Called by everything in the island that sets the level itself — the rail's slider and
    /// mute button, a scroll on the island, and the media keys once the island is the one
    /// answering them.
    static func markLocalWrite() { lastLocalWrite = LocalWrite.now() }

    /// Nothing in the app can set this stamp to an arbitrary moment without writing to real
    /// hardware, so a test that wants to know whether this reads *its own* slider — rather
    /// than the brightness one — has no other way in.
    static func markLocalWriteForTesting(_ stamp: TimeInterval) { lastLocalWrite = stamp }

    func setVolume(_ level: Float) {
        let clamped = max(0, min(1, level))
        Self.markLocalWrite()
        if AudioMonitor.writeOutputVolume(clamped) {
            volume = clamped
            if clamped > 0, isMuted, AudioMonitor.writeOutputMute(false) { isMuted = false }
        }
    }

    func setMuted(_ muted: Bool) {
        Self.markLocalWrite()
        if AudioMonitor.writeOutputMute(muted) { isMuted = muted }
    }

    // MARK: - CoreAudio

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
        streamCount(device, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func inputStreamCount(_ device: AudioDeviceID) -> Int {
        streamCount(device, scope: kAudioDevicePropertyScopeInput)
    }

    private static func streamCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// The output the Mac is playing through right now, read straight from CoreAudio.
    ///
    /// The published `current` only exists while a view is watching, and the volume display
    /// fires whether or not one is. Held between calls because a key held down repeats twenty
    /// times a second and each of those would otherwise cost three blocking property reads on
    /// the main thread: the device's id is asked for every time, its name and kind only when
    /// that id turns out to have changed. Main thread only.
    private static var cachedOutput: Device?

    static func currentOutput() -> Device? {
        let id = AudioMonitor.defaultOutputDevice()
        guard id != 0 else {
            cachedOutput = nil
            return nil
        }
        if let cachedOutput, cachedOutput.id == id { return cachedOutput }
        // A device that will not say its name yet — Bluetooth in the moment it becomes the
        // default — is answered as no device rather than as one called "Output", and nothing
        // is remembered, so the next ask gets the real name instead of the placeholder for
        // the life of the process.
        guard let name = readName(of: id) else { return nil }
        let device = Device(id: id, name: name, transport: transport(of: id))
        cachedOutput = device
        return device
    }

    private static func name(of device: AudioDeviceID) -> String {
        readName(of: device) ?? "Output"
    }

    /// The device's name, or nil when it will not give one.
    private static func readName(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let name = value?.takeRetainedValue() else { return nil }
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

    // MARK: - AirPlay's data sources

    /// The receivers the AirPlay device lists on its output side, by id, or nil when it will not
    /// say. All public CoreAudio; what the AirPlay device does with it is the undocumented part.
    private static func dataSources(of device: AudioDeviceID) -> [UInt32]? {
        uint32List(of: device, selector: kAudioDevicePropertyDataSources, asking: "its AirPlay receivers")
    }

    /// The receivers it is sending to, by id — a list, because AirPlay can play to several.
    private static func selectedDataSources(of device: AudioDeviceID) -> [UInt32]? {
        uint32List(of: device, selector: kAudioDevicePropertyDataSource, asking: "which AirPlay receiver it is on")
    }

    private static func uint32List(of device: AudioDeviceID, selector: AudioObjectPropertySelector,
                                   asking what: String) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else {
            IslandLog.audio.notice("the AirPlay device cannot be asked \(what, privacy: .public)")
            return nil
        }
        var size: UInt32 = 0
        let sized = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard sized == noErr else {
            IslandLog.audio.error("the AirPlay device would not size \(what, privacy: .public): \(sized, privacy: .public)")
            return nil
        }
        let count = Int(size) / MemoryLayout<UInt32>.size
        guard count > 0 else { return [] }
        var ids = [UInt32](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids)
        guard status == noErr else {
            IslandLog.audio.error("the AirPlay device would not say \(what, privacy: .public): \(status, privacy: .public)")
            return nil
        }
        // The list may have shrunk between the two calls; the size that came back is the truth.
        return Array(ids.prefix(Int(size) / MemoryLayout<UInt32>.size))
    }

    /// A receiver's name, through the translation CoreAudio uses for every data source: the id
    /// goes in, a CFString the caller owns comes out. Nil, and logged, when it will not give one.
    private static func dataSourceName(_ source: UInt32, of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var input = source
        var output: Unmanaged<CFString>?
        let status: OSStatus = withUnsafeMutablePointer(to: &input) { inPointer in
            withUnsafeMutablePointer(to: &output) { outPointer in
                var translation = AudioValueTranslation(mInputData: UnsafeMutableRawPointer(inPointer),
                                                        mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                                        mOutputData: UnsafeMutableRawPointer(outPointer),
                                                        mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &translation)
            }
        }
        guard status == noErr else {
            IslandLog.audio.error("the AirPlay device would not name receiver \(source, privacy: .public): \(status, privacy: .public)")
            return nil
        }
        guard let name = output?.takeRetainedValue() else { return nil }
        return name as String
    }
}

/// What the output picker and the Sound column show of AirPlay, from what the AirPlay device
/// said about its data sources. Its behaviour there is undocumented, so every reading is taken
/// with suspicion, and the rules for it are here where a test can hold them.
enum AirPlayList {
    /// One data source as CoreAudio gave it: its id, and whatever name it answered with.
    struct Source: Equatable {
        var id: UInt32
        var name: String?
    }

    static let heading = "AirPlay"

    /// The receivers worth a row: named — a source with no name, or only spaces, is not somewhere
    /// anybody can choose — and not named after the AirPlay device itself, which is the device
    /// standing in for its own list rather than a receiver on it. A source listed twice counts
    /// once. In name order, as the Sound menu lists them.
    static func targets(device: AudioDeviceID, deviceName: String,
                        sources: [Source]) -> [AudioOutputs.AirPlayTarget] {
        var seen: Set<UInt32> = []
        var result: [AudioOutputs.AirPlayTarget] = []
        let own = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        for source in sources {
            guard let name = source.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  name.caseInsensitiveCompare(own) != .orderedSame,
                  seen.insert(source.id).inserted else { continue }
            result.append(AudioOutputs.AirPlayTarget(device: device, source: source.id, name: name))
        }
        return result.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.source < b.source : order == .orderedAscending
        }
    }

    /// The receivers to tick: the selected ones that are listed, and none at all unless the
    /// AirPlay device is where the sound is going — a device that is not the output remembers a
    /// choice nobody is hearing.
    static func ticked(selected: [UInt32], targets: [AudioOutputs.AirPlayTarget],
                       isDefaultOutput: Bool) -> Set<UInt32> {
        guard isDefaultOutput else { return [] }
        return Set(selected).intersection(targets.map(\.source))
    }

    /// The outputs to list beside the AirPlay group. While the group has receivers in it, the
    /// AirPlay device's own row goes: its receivers are the choices, and a row that picks
    /// AirPlay without saying which speaker is not one. With none, it stays as it always was.
    static func outputs(_ devices: [AudioOutputs.Device], airPlay: [AudioOutputs.AirPlayTarget]) -> [AudioOutputs.Device] {
        guard !airPlay.isEmpty else { return devices }
        let listed = Set(airPlay.map(\.device))
        return devices.filter { !($0.transport == kAudioDeviceTransportTypeAirPlay && listed.contains($0.id)) }
    }

    /// Whether the picker has a choice to offer: more than one place between the outputs and the
    /// receivers.
    static func hasChoice(outputs devices: [AudioOutputs.Device], airPlay: [AudioOutputs.AirPlayTarget]) -> Bool {
        outputs(devices, airPlay: airPlay).count + airPlay.count > 1
    }
}
