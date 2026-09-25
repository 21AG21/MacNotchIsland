import AppKit
import Combine

/// Turns "a call app has the microphone" into a call Live Activity with the green phone glyph
/// and running duration, like a FaceTime call in the iPhone's island.
///
/// Which app has it is the whole question. It used to be "the microphone is on and a call app
/// is running", and a call app is nearly always running: Slack idling in the background turned
/// Dictation, a voice memo or a call in a browser tab into a card saying "Slack", at the
/// highest priority the island has. macOS 14.2 can say which processes are recording, so the
/// card goes to the one that is; see `callApp(_:running:)`.
///
/// It follows the call whether or not there is a card for it. The card is the Calls switch in
/// Activities; "Only during calls" in Privacy hides the island from a screen share for the
/// length of a call, and has to know there is one with that switch off too. `call` is that
/// answer.
final class CallDetector: ObservableObject {
    static let shared = CallDetector()

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

    /// The call going on right now, card or no card. Nil while the detector is not running.
    @Published private(set) var call: CallState?

    /// Whether a call is put on the island as a card: the Calls switch. Off, calls are still
    /// followed while the detector runs, and only the card is left out.
    var showsCard = true {
        didSet { if showsCard != oldValue { present(expanding: false) } }
    }

    private var cancellable: AnyCancellable?
    private var running = false

    private init() {}

    /// Follows `audio`'s microphone from now until `stop()`. The current reading arrives at
    /// once, so a detector started in the middle of a call finds it.
    func start(following audio: AudioMonitor) {
        guard !running else { return }
        running = true
        cancellable = audio.$microphone
            .removeDuplicates { !Self.reexamines(from: $0, to: $1) }
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] microphone in self?.evaluate(microphone) }
    }

    func stop() {
        guard running else { return }
        running = false
        cancellable = nil
        call = nil
        ActivityCenter.shared.end(id: "call")
    }

    private func evaluate(_ microphone: AudioMonitor.Microphone) {
        guard running else { return }
        let apps = NSWorkspace.shared.runningApplications
        let step = Self.step(inUse: microphone.inUse, evidence: Self.evidence(microphone.recorders),
                             running: apps.compactMap(\.bundleIdentifier), current: call?.bundleID)
        switch step {
        case .keep:
            return
        case .end:
            call = nil
            present(expanding: false)
        case .begin(let bundle):
            let app = apps.first { $0.bundleIdentifier == bundle }
            let name = Self.callApps[bundle] ?? app?.localizedName ?? "Call"
            call = CallState(appName: name, bundleID: bundle, startedAt: Date())
            present(expanding: true)
        }
    }

    /// Puts the call on the island, or takes it off, as the call and the switch say.
    private func present(expanding: Bool) {
        guard let card = Self.card(for: call, showsCard: showsCard) else {
            ActivityCenter.shared.end(id: "call")
            return
        }
        ActivityCenter.shared.upsert(card)
        if expanding { ActivityCenter.shared.forceExpanded(id: "call", for: 3) }
    }

    /// The card for a call, or none: no call, or the Calls switch off.
    static func card(for call: CallState?, showsCard: Bool) -> IslandActivity? {
        guard showsCard, let call else { return nil }
        return IslandActivity(id: "call", kind: .call, content: .call(call), priority: 100,
                              presentation: .expanded, openAction: .app(bundleID: call.bundleID))
    }

    // MARK: - When to look again

    /// Whether a change in the microphone is worth looking at who has it again.
    ///
    /// Any change at all, the recorders as much as the Bool. The Bool alone was the old key, and
    /// a microphone that was already on — Dictation left running, a voice memo, or, before the
    /// recorders were asked, a headset playing music — did not move when a call started on it,
    /// so the call was never looked at. The same recorders in another order are the same
    /// recorders.
    static func reexamines(from old: AudioMonitor.Microphone, to new: AudioMonitor.Microphone) -> Bool {
        old != new
    }

    /// What a fresh look does to the call.
    enum Step: Equatable {
        /// Nothing: no call and none begun, or the call still going.
        case keep
        /// The call is over.
        case end
        /// A call in this app has begun, or has taken over from the one there was.
        case begin(String)
    }

    /// The call after a change in the microphone.
    ///
    /// A microphone that has gone off ends any call. One that is on keeps the call there is for
    /// as long as its app is still among the recorders; where they cannot be known, on 14.0 and
    /// 14.1, it keeps it for as long as the microphone is on, since nothing could say otherwise.
    /// A call app no longer recording has finished its call even while something else still
    /// records — a card used to outlive its call for as long as a headset went on playing.
    /// Without a call, one begins wherever `callApp(_:running:)` finds one.
    ///
    /// Pure, so the rule can be read back without a microphone or a call.
    static func step(inUse: Bool, evidence: Evidence, running: [String], current: String?) -> Step {
        guard inUse else { return current == nil ? .keep : .end }
        let found = callApp(evidence, running: running)
        guard let current else { return found.map { Step.begin($0) } ?? .keep }
        guard case .recording(let processes) = evidence else { return .keep }
        if processes.contains(where: { callApp(recordedBy: $0, running: running) == current }) { return .keep }
        return found.map { Step.begin($0) } ?? .end
    }

    // MARK: - Whose microphone it is

    /// What can be known about who has the microphone.
    enum Evidence: Equatable {
        /// The bundle identifiers of the processes recording right now — a pid for one with no
        /// bundle, which no call app will match: macOS 14.2 and later.
        case recording([String])
        /// Only which app is in front: macOS 14.0 and 14.1 cannot say who is recording.
        case frontmost(String?)
        /// macOS was asked who is recording and did not answer.
        case unknown
    }

    /// The call app the microphone belongs to, or nothing.
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

    /// Who is recording, from the audio monitor's last reading where macOS can say, and
    /// otherwise which app is in front.
    private static func evidence(_ recorders: Set<String>?) -> Evidence {
        guard #available(macOS 14.2, *) else {
            return .frontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        // Sorted, so which of two call apps recording at once gets the card does not depend on
        // the order a set happens to hold them in.
        return recorders.map { Evidence.recording($0.sorted()) } ?? .unknown
    }
}
