import AppKit
import Combine

/// Turns "microphone in use + a call app is running" into a call Live Activity with the
/// green phone glyph and running duration, like a FaceTime call in the iPhone's island.
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
        let running = NSWorkspace.shared.runningApplications
        guard let app = running.first(where: { app in
            guard let id = app.bundleIdentifier else { return false }
            return Self.callApps[id] != nil
        }), let bundle = app.bundleIdentifier else { return }
        let name = Self.callApps[bundle] ?? app.localizedName ?? "Call"
        let state = CallState(appName: name, bundleID: bundle, startedAt: Date())
        let activity = IslandActivity(id: "call", kind: .call, content: .call(state), priority: 100,
                                      presentation: .expanded, openAction: .app(bundleID: bundle))
        ActivityCenter.shared.upsert(activity)
        ActivityCenter.shared.forceExpanded(id: "call", for: 3)
    }
}
