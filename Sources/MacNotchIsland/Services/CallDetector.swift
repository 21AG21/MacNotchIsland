import AppKit
import Combine
import CoreAudio

/// Turns "a call app has the microphone" into a call Live Activity with the green phone glyph
/// and running duration, like a FaceTime call in the iPhone's island.
///
/// Which app has it is the whole question. It used to be "the microphone is on and a call app
/// is running", and a call app is nearly always running: Slack idling in the background turned
/// Dictation, a voice memo or a call in a browser tab into a card saying "Slack", at the
/// highest priority the island has. macOS 14.2 can say which processes are recording, so the
/// card goes to the one that is; see `callApp(_:running:)`.
final class CallDetector {
    private static let callApps: [String: String] = [
        "com.apple.FaceTime": "FaceTime",
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan": "Google Meet",
        "com.skype.skype": "Skype",
        "com.loom.desktop": "Loom",
    ]

    /// Processes that record on a call app's behalf rather than being one. FaceTime hands its
    /// calls to the system's conferencing daemon, so the process with the microphone is not
    /// FaceTime itself. Counted only while the app it works for is running.
    private static let recordsFor: [String: String] = [
        "com.apple.avconferenced": "com.apple.FaceTime",
    ]

    private var cancellable: AnyCancellable?
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        cancellable = ActivityCenter.shared.$micInUse
            .removeDuplicates()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] inUse in self?.evaluate(micInUse: inUse) }
    }

    func stop() {
        guard running else { return }
        running = false
        cancellable = nil
        ActivityCenter.shared.end(id: "call")
    }

    private func evaluate(micInUse: Bool) {
        guard micInUse else {
            ActivityCenter.shared.end(id: "call")
            return
        }
        guard ActivityCenter.shared.activity(id: "call") == nil else { return }
        let apps = NSWorkspace.shared.runningApplications
        guard let bundle = Self.callApp(Self.evidence(), running: apps.compactMap(\.bundleIdentifier)) else { return }
        let app = apps.first { $0.bundleIdentifier == bundle }
        let name = Self.callApps[bundle] ?? app?.localizedName ?? "Call"
        let state = CallState(appName: name, bundleID: bundle, startedAt: Date())
        let activity = IslandActivity(id: "call", kind: .call, content: .call(state), priority: 100,
                                      presentation: .expanded, openAction: .app(bundleID: bundle))
        ActivityCenter.shared.upsert(activity)
        ActivityCenter.shared.forceExpanded(id: "call", for: 3)
    }

    // MARK: - Whose microphone it is

    /// What can be known about who has the microphone.
    enum Evidence: Equatable {
        /// The bundle identifiers of the processes recording right now: macOS 14.2 and later.
        case recording([String])
        /// Only which app is in front: macOS 14.0 and 14.1 cannot say who is recording.
        case frontmost(String?)
        /// macOS was asked who is recording and did not answer.
        case unknown
    }

    /// The call app a microphone that has just come on belongs to, or nothing.
    ///
    /// With the recorders known, only a call app among them — or one of its helpers, or the
    /// daemon recording for it — gets a card, and a call app merely running gets nothing.
    /// Without them, on 14.0 and 14.1, the call app has to be the one in front, which is where
    /// a call is while it is being answered. A question macOS would not answer falls back to
    /// the old rule, the first call app running, rather than to no call card at all.
    ///
    /// Pure, so the rule can be read back without a microphone or a call.
    static func callApp(_ evidence: Evidence, running: [String]) -> String? {
        switch evidence {
        case .recording(let processes):
            for process in processes {
                if let app = callApp(recordedBy: process, running: running) { return app }
            }
            return nil
        case .frontmost(let front):
            guard let front, callApps[front] != nil else { return nil }
            return front
        case .unknown:
            return running.first { callApps[$0] != nil }
        }
    }

    /// The call app one recording process stands for, if it stands for one.
    private static func callApp(recordedBy process: String, running: [String]) -> String? {
        if callApps[process] != nil { return process }
        // Chromium and Electron apps record in a helper named after them:
        // "com.tinyspeck.slackmacgap.helper" is Slack. The dot keeps "teams2" out of "teams".
        if let app = callApps.keys.sorted().first(where: { process.hasPrefix($0 + ".") }) { return app }
        if let app = recordsFor[process], running.contains(app) { return app }
        // A web app in a window of its own records in its browser's helper, so a recording
        // Chrome helper is Google Meet when the Meet app is open.
        let browser = process.range(of: ".helper").map { String(process[..<$0.lowerBound]) } ?? process
        return running.first { callApps[$0] != nil && $0.hasPrefix(browser + ".app.") }
    }

    /// Asks macOS who is recording where it can say, and otherwise which app is in front.
    private static func evidence() -> Evidence {
        guard #available(macOS 14.2, *) else {
            return .frontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        return recordingProcesses().map { Evidence.recording($0) } ?? .unknown
    }

    /// The bundle identifiers of every process Core Audio says is taking input, or nil when
    /// the list itself could not be read.
    @available(macOS 14.2, *)
    private static func recordingProcesses() -> [String]? {
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
        return processes.prefix(Int(size) / each).compactMap { process in
            isRecording(process) ? bundleID(of: process) : nil
        }
    }

    @available(macOS 14.2, *)
    private static func isRecording(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
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
}
