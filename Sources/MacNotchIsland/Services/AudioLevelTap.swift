import Foundation
import Combine
import CoreAudio
import AudioToolbox

/// System audio level for the reactive visualizer.
///
/// macOS 14.2 made Core Audio *process taps* public: a tap is a virtual input that carries
/// audio another process (or the whole system mix) is playing. We create a stereo-mixdown
/// tap of everything, hang it off a private aggregate device, and reduce each IO cycle to a
/// single RMS number the Now Playing bars can dance to. Nothing is recorded, nothing is
/// written to disk, and the tap is `.unmuted` so playback is untouched.
///
/// Cheapness rules the lifetime: the tap only exists while something is actually playing
/// *and* `EnergyPolicy` still allows animation, so the resting state is "no tap at all".
/// Below macOS 14.2 every method is a no-op and `isRunning` stays false.
final class AudioLevelTap: ObservableObject {
    static let shared = AudioLevelTap()

    /// 0…1, smoothed, published at most ~20 Hz while running.
    @Published private(set) var level: Double = 0
    @Published private(set) var isRunning = false

    // MARK: Tuning (shared with the tests)

    /// Weight applied when the level is rising — bars snap up on a transient.
    static let attack = 0.5
    /// Weight applied when the level is falling — bars sink like a VU meter needle.
    static let release = 0.12
    /// How many dB below full scale map to a level of 0.
    static let floorDB = 50.0

    /// Never publish more often than this, in seconds (20 Hz).
    private static let publishInterval = 1.0 / 20.0

    // MARK: State (main thread only)

    /// True between `start()` and `stop()`; the tap itself may still be down.
    private var wanted = false
    private var cancellables = Set<AnyCancellable>()
    private var loggedFailure = false
    private var settingUp = false
    private var rebuildRequested = false
    private var attempts = 0
    private static let maxAttempts = 3
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var deviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)

    // MARK: State (audioQueue only)

    /// Every Core Audio call happens here: creating the first tap shows the system's
    /// audio-capture consent sheet, which blocks the calling thread until it is answered.
    private let audioQueue = DispatchQueue(label: "com.macnotchisland.audiotap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // MARK: State (IO thread only)

    private var ioLevel = 0.0
    private var lastPublish = 0.0

    private init() {}

    // MARK: Lifecycle

    /// Allow the tap to run. It is only actually created while something is playing and the
    /// energy policy has not paused animation.
    func start() {
        guard !wanted else { return }
        wanted = true
        attempts = 0
        // Both publishers fire *before* their value lands (Combine's willChange), so hop
        // through the main queue and re-read the state instead of trusting the payload.
        NowPlayingService.shared.$info
            .map { $0?.isPlaying == true }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        EnergyPolicy.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        listenForOutputDeviceChanges()
        evaluate()
    }

    /// Stop observing and tear the tap down. Safe to call when nothing was ever started.
    func stop() {
        wanted = false
        cancellables.removeAll()
        stopListeningForOutputDeviceChanges()
        attempts = 0
        teardown()
    }

    /// Decides whether a tap should be live right now, and makes it so.
    private func evaluate() {
        let playing = NowPlayingService.shared.info?.isPlaying == true
        if wanted && playing && !EnergyPolicy.shared.animationsPaused {
            setUp()
        } else {
            teardown()
        }
    }

    /// Builds the tap on `audioQueue`. After a few consecutive failures (a declined consent
    /// sheet, no output device) it stops retrying until the feature is switched off and on.
    private func setUp() {
        guard !isRunning, !settingUp, attempts < Self.maxAttempts else { return }
        // Process taps are macOS 14.2; on 14.0/14.1 the visualizer keeps its synthetic bars.
        guard #available(macOS 14.2, *) else { return }
        settingUp = true
        attempts += 1
        audioQueue.async { [weak self] in
            guard let self else { return }
            let ok = self.startTap()
            DispatchQueue.main.async {
                self.settingUp = false
                if ok {
                    self.attempts = 0
                    self.isRunning = true
                }
                // Playback may have stopped, the output may have changed, or the feature may
                // have been turned off while the consent sheet was up: settle it now.
                if self.rebuildRequested {
                    self.rebuildRequested = false
                    self.teardown()
                }
                self.evaluate()
            }
        }
    }

    // MARK: Output device changes

    private func listenForOutputDeviceChanges() {
        guard deviceListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputDeviceChanged() }
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, DispatchQueue.main, block)
        deviceListener = block
    }

    private func stopListeningForOutputDeviceChanges() {
        guard let block = deviceListener else { return }
        _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, DispatchQueue.main, block)
        deviceListener = nil
    }

    /// The aggregate device clocks against the output that was current when the tap was
    /// built; after a switch (AirPods on, a display with speakers) it must be rebuilt.
    private func outputDeviceChanged() {
        if settingUp {
            rebuildRequested = true
            return
        }
        guard isRunning else { return }
        teardown()
        evaluate()
    }

    // MARK: Core Audio

    @available(macOS 14.2, *)
    private func startTap() -> Bool {
        // 1. A tap over the entire system mix. An empty process list means "everything";
        //    creating the first one is what makes macOS ask for audio-capture consent.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        let tapUID = tapDescription.uuid.uuidString
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard status == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            return failed("could not create the system audio tap (status \(status)).")
        }
        tapID = tap

        // 2. A private aggregate device that owns the tap and follows the default output.
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            return failed("no default output device to attach the audio tap to.")
        }
        let subDevice: [String: Any] = [kAudioSubDeviceUIDKey: outputUID]
        let subTap: [String: Any] = [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapUID,
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchIslandTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [subDevice],
            kAudioAggregateDeviceTapListKey: [subTap],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate != AudioObjectID(kAudioObjectUnknown) else {
            return failed("could not create the aggregate device for the audio tap (status \(status)).")
        }
        aggregateID = aggregate

        // 3. One IO block per cycle, called on Core Audio's own thread.
        ioLevel = 0
        lastPublish = 0
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            self.consume(input)
        }
        guard status == noErr, let proc else {
            return failed("could not install the audio tap IO block (status \(status)).")
        }
        procID = proc

        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else {
            return failed("could not start the audio tap device (status \(status)).")
        }
        return true
    }

    /// Main thread: publish the resting state, then release the Core Audio handles.
    private func teardown() {
        if isRunning { isRunning = false }
        if level != 0 { level = 0 }
        audioQueue.async { [weak self] in self?.destroyHandles() }
    }

    /// audioQueue only: undoes `startTap()` in the reverse order, skipping whatever was never created.
    private func destroyHandles() {
        if let proc = procID {
            if aggregateID != AudioObjectID(kAudioObjectUnknown) {
                _ = AudioDeviceStop(aggregateID, proc)
                _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            procID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        ioLevel = 0
        lastPublish = 0
    }

    /// audioQueue only: logs the first failure (a declined consent sheet would otherwise log
    /// forever) and makes sure nothing half-built is left behind.
    private func failed(_ message: String) -> Bool {
        if !loggedFailure {
            loggedFailure = true
            IslandLog.audio.error("\(message, privacy: .public)")
        }
        destroyHandles()
        return false
    }

    /// UID of the current default output device, which the aggregate device clocks against.
    private static func defaultOutputDeviceUID() -> String? {
        let device = AudioMonitor.defaultOutputDevice()
        guard device != 0 else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    // MARK: IO thread

    // Two overloads so this compiles whether the SDK imports the IO block's input buffer
    // list as optional or not; both hand off to `measure(_:)`.
    private func consume(_ list: UnsafePointer<AudioBufferList>) {
        measure(list)
    }

    private func consume(_ list: UnsafePointer<AudioBufferList>?) {
        if let list { measure(list) }
    }

    /// Called on Core Audio's IO thread: reduce the cycle to one number, smooth it, and
    /// forward it to the main thread no more than 20 times a second.
    private func measure(_ list: UnsafePointer<AudioBufferList>) {
        let target = Self.levelFromRMS(Self.rms(of: list))
        let next = Self.smoothed(previous: ioLevel, target: target)
        ioLevel = next
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPublish >= Self.publishInterval else { return }
        lastPublish = now
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            if abs(self.level - next) > 0.001 { self.level = next }
        }
    }

    // MARK: Pure helpers (unit-testable without any audio hardware)

    /// Root mean square over every Float32 sample in the buffer list. Interleaved and
    /// non-interleaved layouts both work: each buffer is just a run of samples.
    static func rms(of list: UnsafePointer<AudioBufferList>) -> Float {
        let mutable = UnsafeMutablePointer<AudioBufferList>(mutating: list)
        let buffers = UnsafeMutableAudioBufferListPointer(mutable)
        var sum = 0.0
        var count = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            guard samples > 0 else { continue }
            let values = data.assumingMemoryBound(to: Float32.self)
            for index in 0..<samples {
                let value = Double(values[index])
                sum += value * value
            }
            count += samples
        }
        guard count > 0 else { return 0 }
        return Float((sum / Double(count)).squareRoot())
    }

    /// Maps an RMS amplitude to a 0…1 bar level on a dB curve, so quiet passages still move
    /// the bars. Silence (and anything below `floorDB` under full scale) is 0, full scale 1.
    static func levelFromRMS(_ rms: Float) -> Double {
        let value = Double(rms)
        guard value.isFinite, value > 0 else { return 0 }
        let decibels = 20 * log10(value)
        return max(0, min(1, 1 + decibels / floorDB))
    }

    /// One smoothing step: fast attack, slow release, always clamped to 0…1.
    static func smoothed(previous: Double, target: Double) -> Double {
        let weight = target > previous ? attack : release
        return max(0, min(1, previous + (target - previous) * weight))
    }
}
