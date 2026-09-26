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

    /// Main thread.
    private var viewers = 0
    /// One reading at a time, and an ask made while one is in the air answered by one more
    /// when it lands. Main thread.
    private var pass = RadioPass()

    /// Where CoreAudio is read, where the output is switched, and where every listener is
    /// added and taken away.
    ///
    /// None of that is done on the main thread any more. A reading is every device's stream
    /// counts on both sides, its name and its kind, the AirPlay device's receivers and their
    /// names, and the level: dozens of round trips to the audio server, with the AirPlay
    /// device's answers the least predictable of them. It ran on the main thread on the turn
    /// after the rail was mounted, which is inside the spring that opens the panel, and again
    /// on every change to the device list. Serial, so a switch made from the menu is written
    /// ahead of the reading that shows it, and the listeners are added and removed in the
    /// order they were asked for.
    private let reader = DispatchQueue(label: "com.macnotchisland.audio-outputs", qos: .userInitiated)
    // On `reader`.
    private var systemRegistrations: [Registration] = []
    private var deviceRegistrations: [Registration] = []
    private var boundDevice: AudioDeviceID = 0
    /// The AirPlay device's list of receivers and its choice among them, watched so a HomePod
    /// that wakes up joins the list without the panel being opened again.
    private var airPlayRegistrations: [Registration] = []
    private var boundAirPlay: AudioDeviceID = 0
    /// Where the listeners are called: the main queue, which is where what they ask for is
    /// decided. What they ask for is handed straight back to `reader`.
    private let callbacks = DispatchQueue.main

    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
        /// Whether CoreAudio took the listener.
        var landed: Bool
        /// A level listener put on before the output had that property, or one CoreAudio would
        /// not take: put on again once the property is there (`listenAgainForArrivedLevel`).
        var early = false
    }

    private init() {}

    // MARK: - Lifetime

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        reader.async { [weak self] in self?.watchSystem() }
        reloadDevices()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        reader.async { [weak self] in self?.unwatchAll() }
    }

    /// On `reader`. The default input is heard as well as the default output: an input picked
    /// in System Settings otherwise left the old one ticked in the Sound column and the rail's
    /// menu until the panel was opened again.
    private func watchSystem() {
        guard systemRegistrations.isEmpty else { return }
        systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices,
                                          scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.reloadDevices() })
        systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice,
                                          scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.reloadDevices() })
        systemRegistrations.append(listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice,
                                          scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.reloadDevices() })
    }

    /// On `reader`.
    private func unwatchAll() {
        remove(&systemRegistrations)
        remove(&deviceRegistrations)
        remove(&airPlayRegistrations)
        boundDevice = 0
        boundAirPlay = 0
    }

    // MARK: - Reading

    /// Asks for a fresh look at the devices. Main thread, from a listener, a switch or a view
    /// appearing; returns at once, having handed the asking to `reader`.
    func reloadDevices() {
        // The gallery is handed its devices; a reading here would take them away again.
        guard !RenderMode.isGallery else { return }
        guard pass.start() else { return }
        // Listeners are only left behind while something shows what they report: a reading
        // asked for with nothing on screen must not add ones nothing will take down.
        let watching = viewers > 0
        reader.async { [weak self] in
            guard let self else { return }
            var reading = Self.read()
            // The listeners first and the level last, so no change to it falls between the two:
            // one made after this read is heard by a listener, and one made before it is in it.
            // Read the other way round, a change landing between them was in neither.
            reading.rebound = self.bind(output: watching ? reading.defaultOutput : 0,
                                        airPlay: watching ? reading.airPlayDevice : 0)
            reading.volume = AudioMonitor.readOutputVolume(device: reading.defaultOutput)
            reading.mute = AudioMonitor.readOutputMute(device: reading.defaultOutput)
            DispatchQueue.main.async { [weak self] in self?.show(reading) }
        }
    }

    /// One whole look at the Mac's sound devices, taken on `reader`.
    private struct Reading {
        var outputs: [Device]
        var inputs: [Device]
        var defaultOutput: AudioDeviceID
        var defaultInput: AudioDeviceID
        /// The AirPlay device, or 0 where there is none.
        var airPlayDevice: AudioDeviceID
        var airPlay: [AirPlayTarget]
        var ticked: Set<UInt32>
        /// Read last, after `bind`; see `reloadDevices`.
        var volume: Float? = nil
        var mute: Bool? = nil
        /// The listeners moved to another output with this reading. See `showsLevel`.
        var rebound = false
    }

    /// Everything the rail and the menu show, in one pass over the device list. On `reader`.
    ///
    /// The AirPlay device's receivers are read as its data sources — the way the Sound pane
    /// listed AirPlay speakers when it listed them at all — on every reading, which is every
    /// change to the device list, the default output and the default input, and whenever the
    /// AirPlay device says its list or its choice has changed. The level is not read here: it is
    /// read after the listeners are in place (`reloadDevices`).
    private static func read() -> Reading {
        let ids = allDeviceIDs()
        let outputs = ids.filter { outputStreamCount($0) > 0 }.map(device(for:)).sorted(by: listedBefore)
        let inputs = ids.filter { inputStreamCount($0) > 0 }.map(device(for:)).sorted(by: listedBefore)
        let defaultOutput = AudioMonitor.defaultOutputDevice()
        let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let air = outputs.first { $0.transport == kAudioDeviceTransportTypeAirPlay }
        var targets: [AirPlayTarget] = []
        var ticked: Set<UInt32> = []
        if let air {
            let sources = (dataSources(of: air.id) ?? []).map {
                AirPlayList.Source(id: $0, name: dataSourceName($0, of: air.id))
            }
            targets = AirPlayList.targets(device: air.id, deviceName: air.name, sources: sources)
            if !targets.isEmpty {
                ticked = AirPlayList.ticked(selected: selectedDataSources(of: air.id) ?? [],
                                            targets: targets, isDefaultOutput: air.id == defaultOutput)
            }
        }
        return Reading(outputs: outputs, inputs: inputs, defaultOutput: defaultOutput, defaultInput: defaultInput,
                       airPlayDevice: air?.id ?? 0, airPlay: targets, ticked: ticked)
    }

    private static func device(for id: AudioDeviceID) -> Device {
        Device(id: id, name: name(of: id), transport: transport(of: id))
    }

    /// The Mac's own first, then by name.
    private static func listedBefore(_ a: Device, _ b: Device) -> Bool {
        if (a.transport == kAudioDeviceTransportTypeBuiltIn) != (b.transport == kAudioDeviceTransportTypeBuiltIn) {
            return a.transport == kAudioDeviceTransportTypeBuiltIn
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// Wherever an output might keep its level — see `AudioMonitor.volumeElements` — and its
    /// mute. Watching only the synthesised main volume left the rail's slider frozen on a
    /// device that has none, while the media keys moved it.
    private static let levelAddresses: [AudioObjectPropertyAddress] =
        AudioMonitor.volumeElements.map { AudioMonitor.volumeAddress(element: $0) }
        + [AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                      mElement: kAudioObjectPropertyElementMain)]

    /// Moves the listeners onto the output and the AirPlay device a reading found, or takes
    /// them away (0), and says whether the output's listeners moved. On `reader`.
    ///
    /// A reading that finds the same output puts back on any level listener that went on
    /// before its property was there (`listenAgainForArrivedLevel`). AirPods or an AirPlay
    /// receiver can become the output before they have published a level or a mute, and a
    /// listener put on a property that does not exist yet cannot be counted on to report it
    /// arriving, or anything after.
    @discardableResult
    private func bind(output: AudioDeviceID, airPlay: AudioDeviceID) -> Bool {
        let rebound = boundDevice != output
        if rebound {
            remove(&deviceRegistrations)
            boundDevice = output
            if output != 0 {
                deviceRegistrations = Self.levelAddresses.map { listenForLevel(on: output, at: $0) }
                // What the output owns changes as its controls arrive, the level among them: a
                // reading then shows what the last one could not (`showsLevel`) and puts the
                // early listeners back on.
                deviceRegistrations.append(listen(output, selector: kAudioObjectPropertyOwnedObjects,
                                                  scope: kAudioObjectPropertyScopeGlobal) { [weak self] in self?.reloadDevices() })
            }
        } else if output != 0 {
            listenAgainForArrivedLevel(on: output)
        }
        if boundAirPlay != airPlay {
            remove(&airPlayRegistrations)
            boundAirPlay = airPlay
            if airPlay != 0 {
                for selector in [kAudioDevicePropertyDataSources, kAudioDevicePropertyDataSource] {
                    airPlayRegistrations.append(listen(airPlay, selector: selector, scope: kAudioDevicePropertyScopeOutput) {
                        [weak self] in self?.reloadDevices()
                    })
                }
            }
        }
        return rebound
    }

    /// A listener for one of `levelAddresses` on `output`, marked `early` when the output does
    /// not have that property yet or CoreAudio would not take it. On `reader`.
    private func listenForLevel(on output: AudioDeviceID, at address: AudioObjectPropertyAddress) -> Registration {
        var asked = address
        let present = AudioObjectHasProperty(output, &asked)
        var registration = listen(output, address: address) { [weak self] in self?.reloadLevel() }
        registration.early = !present || !registration.landed
        return registration
    }

    /// Puts back on each early level listener whose property the output has now, so the
    /// output's own listener reports that level from here on. On `reader`, from `bind`, which
    /// is before the reading reads the level.
    private func listenAgainForArrivedLevel(on output: AudioDeviceID) {
        for index in deviceRegistrations.indices where deviceRegistrations[index].early {
            var address = deviceRegistrations[index].address
            guard AudioObjectHasProperty(output, &address) else { continue }
            var stale = [deviceRegistrations[index]]
            remove(&stale)
            deviceRegistrations[index] = listenForLevel(on: output, at: address)
        }
    }

    /// Where every reading lands. Main thread, and the only place the list is published.
    private func show(_ reading: Reading) {
        let again = pass.finish()
        if reading.outputs != devices { devices = reading.outputs }
        let output = reading.outputs.first { $0.id == reading.defaultOutput }
        if output != current { current = output }
        if reading.inputs != inputs { inputs = reading.inputs }
        let input = reading.inputs.first { $0.id == reading.defaultInput }
        if input != currentInput { currentInput = input }
        if reading.airPlay != airPlay { airPlay = reading.airPlay }
        if reading.ticked != airPlayCurrent { airPlayCurrent = reading.ticked }
        let parts = Self.showsLevel(rebound: reading.rebound, wroteRecently: Self.wroteRecently(),
                                    shownVolume: volume, shownHasMute: hasMute,
                                    readVolume: reading.volume, readMute: reading.mute)
        showLevel(volume: reading.volume, mute: reading.mute, parts: parts)
        // Something changed while this reading was in the air; the answer it is waiting for is
        // the next one.
        if again { reloadDevices() }
    }

    /// Which halves of a level `showLevel` sets.
    struct LevelParts: OptionSet {
        let rawValue: Int
        static let volume = LevelParts(rawValue: 1 << 0)
        static let mute = LevelParts(rawValue: 1 << 1)
        static let all: LevelParts = [.volume, .mute]
    }

    /// Which of a reading's level to show. Pure, so it is tested.
    ///
    /// All of it when the listeners moved to a new output with it: until then the level shown
    /// is some other device's, and from then on the new device's listeners report every change
    /// (`reloadLevel`), exactly and on the main thread. A reading that went round by `reader`
    /// took longer, and applied afterwards it could put back a level one of those listeners had
    /// already moved past. That holds even when the island wrote the level a moment ago: the
    /// write was to the output before, so the new one's level is never the one just written,
    /// and a write to the new one after the reading read it is reported by the listener `bind`
    /// put on before that read. Held back for the write, the rail kept the old output's level
    /// and mute, and the slider's next write stepped from them.
    ///
    /// Otherwise only what is shown as missing and the reading has: a level where none is shown,
    /// a mute where the output is shown as having none. AirPods or an AirPlay receiver picked as
    /// the output can have neither yet when the reading that moved the listeners reads them, and
    /// the slider stayed disabled until the level moved some other way. Nothing a listener
    /// reported is put back that way: there was nothing there for it to report.
    ///
    /// And for the same output, not even that when the island wrote the level a moment ago: a
    /// level read before the slider moved lands after it, and must not pull the slider back for
    /// a frame; the device's own listener reports where it really settled.
    static func showsLevel(rebound: Bool, wroteRecently: Bool, shownVolume: Float?, shownHasMute: Bool,
                           readVolume: Float?, readMute: Bool?) -> LevelParts {
        if rebound { return .all }
        guard !wroteRecently else { return [] }
        var parts: LevelParts = []
        if shownVolume == nil, readVolume != nil { parts.insert(.volume) }
        if !shownHasMute, readMute != nil { parts.insert(.mute) }
        return parts
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

    /// Listens through this one instead. The same write the Sound pane makes, on `reader`.
    func selectInput(_ device: Device) {
        reader.async { [weak self] in
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var id = device.id
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                    UInt32(MemoryLayout<AudioDeviceID>.size), &id)
            if status != noErr {
                IslandLog.island.error("could not switch the input: \(status, privacy: .public)")
            }
            DispatchQueue.main.async { self?.reloadDevices() }
        }
    }

    /// The level and the mute, read where they are shown. Two reads, from the device's own
    /// listeners, and exact: a reading that went round by the queue could land behind the
    /// slider's next write.
    private func reloadLevel() {
        showLevel(volume: AudioMonitor.readOutputVolume(), mute: AudioMonitor.readOutputMute())
    }

    private func showLevel(volume v: Float?, mute m: Bool?, parts: LevelParts = .all) {
        if parts.contains(.volume), v != volume { volume = v }
        guard parts.contains(.mute) else { return }
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

    /// Sends the sound to `device`, on `reader`: switching output can wait on the device being
    /// switched to, and the menu that asked has already closed.
    func select(_ device: Device) {
        reader.async { [weak self] in
            let status = Self.writeDefaultOutput(device.id)
            if status != noErr { IslandLog.audio.error("could not select output \(device.name, privacy: .public): \(status, privacy: .public)") }
            DispatchQueue.main.async { self?.reloadDevices() }
        }
    }

    /// The two writes that send the sound to an AirPlay receiver, in the order they are made.
    enum AirPlayStep: Equatable {
        /// The AirPlay device becomes the default output.
        case output
        /// Its data source is set to the receiver.
        case receiver
    }

    /// The output to put back when sending the sound to a receiver was refused at `failed`, or
    /// nil when there is nothing to undo. A refused first step never moved the output. A refused
    /// second step comes after the first has moved it, and the AirPlay device is then left
    /// playing to whichever receiver it last had, or to none — so the output that was playing
    /// before goes back. Unless that was the AirPlay device already, which is still where it
    /// was, or CoreAudio could not say what it was (0), where writing a guess back would be one
    /// more wrong turn. Pure.
    static func rollback(previous: AudioDeviceID, airPlay: AudioDeviceID, after failed: AirPlayStep) -> AudioDeviceID? {
        switch failed {
        case .output: return nil
        case .receiver: return previous == 0 || previous == airPlay ? nil : previous
        }
    }

    /// Sends the sound to one AirPlay receiver: the AirPlay device becomes the output first, and
    /// then its data source is set to the receiver, which is the order the Sound pane did it in.
    /// Every step that CoreAudio refuses is logged by name, because how the AirPlay device
    /// answers this on a given macOS is not written down anywhere. A refusal leaves the output
    /// where it was, wherever CoreAudio could say where that was — a refused receiver by putting
    /// back the output the first step moved away from, as `rollback` decides — and the route
    /// picker under the list is still there to do it the system's way.
    ///
    /// On `reader`: switching the output waits on the audio server and on the AirPlay device,
    /// and the menu that asked has already closed.
    func selectAirPlay(_ target: AirPlayTarget) {
        reader.async { [weak self] in
            Self.send(to: target)
            DispatchQueue.main.async { self?.reloadDevices() }
        }
    }

    /// The writes `selectAirPlay` makes, in order. On `reader`.
    private static func send(to target: AirPlayTarget) {
        // Read before anything is written: the one to go back to if the receiver says no.
        let previous = AudioMonitor.defaultOutputDevice()
        var failed: AirPlayStep?
        let madeDefault = Self.writeDefaultOutput(target.device)
        if madeDefault != noErr {
            IslandLog.audio.error("could not make AirPlay the output for \(target.name, privacy: .public): \(madeDefault, privacy: .public)")
            failed = .output
        } else {
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
                failed = .receiver
            }
        }
        if let failed, let back = Self.rollback(previous: previous, airPlay: target.device, after: failed) {
            let restored = Self.writeDefaultOutput(back)
            if restored != noErr {
                IslandLog.audio.error("could not put the output back after \(target.name, privacy: .public) refused: \(restored, privacy: .public)")
            }
        }
    }

    /// Makes `device` the system's default output: the write the Sound pane makes.
    private static func writeDefaultOutput(_ device: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id)
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
        let status = AudioObjectAddPropertyListenerBlock(object, &address, callbacks, block)
        return Registration(object: object, address: address, block: block, landed: status == noErr)
    }

    private func remove(_ registrations: inout [Registration]) {
        for var r in registrations {
            _ = AudioObjectRemovePropertyListenerBlock(r.object, &r.address, callbacks, r.block)
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
