import AppKit

/// Third-party Live Activities and alerts through the `notchisland://` URL scheme
/// (works from Shortcuts' "Open URLs", scripts, CI hooks) and a distributed notification.
///
///   notchisland://activity?id=build&title=Building&subtitle=xcodebuild&symbol=hammer.fill&tint=blue&progress=0.4&trailing=40%25&ttl=600&expanded=1&ring=1&url=https://…
///   notchisland://activity/end?id=build
///   notchisland://alert?title=Deployed&symbol=checkmark.circle.fill&tint=green&duration=3
///   notchisland://timer?minutes=5&label=Tea       notchisland://timer/cancel | pause | resume
///   notchisland://timer/pomodoro?work=25&rest=5&cycles=4&long=15
///   notchisland://stopwatch | stopwatch/lap | stopwatch/stop | stopwatch/reset
///   notchisland://shelf/add?path=/Users/me/file.pdf   notchisland://shelf/clear
///   notchisland://home                            notchisland://settings/island
///   Panes: general, island, activities, home, media, actions (or shortcuts), privacy, about
final class LiveActivityAPI {
    static let shared = LiveActivityAPI()
    static let notificationName = Notification.Name("com.macnotchisland.api")

    private var token: NSObjectProtocol?

    func start() {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(forName: Self.notificationName, object: nil, queue: .main) { [weak self] note in
            if let s = note.userInfo?["url"] as? String, let url = URL(string: s) { self?.handle(url) }
            else if let s = note.object as? String, let url = URL(string: s) { self?.handle(url) }
        }
    }

    /// Third-party activities may only open web links, never file: or other schemes.
    static func safeLink(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "notchisland",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let host = (components.host ?? "").lowercased()
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        var q: [String: String] = [:]
        for item in components.queryItems ?? [] { q[item.name.lowercased()] = item.value ?? "" }

        let center = ActivityCenter.shared
        switch (host, path) {
        case ("activity", ""), ("activity", "start"), ("activity", "update"):
            let id = q["id"] ?? "custom"
            var custom = CustomActivity(title: q["title"] ?? "Activity")
            custom.subtitle = q["subtitle"]
            custom.symbol = q["symbol"] ?? q["icon"] ?? "app.fill"
            custom.tint = q["tint"] ?? q["color"] ?? "white"
            custom.progress = q["progress"].flatMap { Double($0) }.map { min(1, max(0, $0)) }
            custom.trailingText = q["trailing"]
            custom.body = q["body"]
            custom.url = Self.safeLink(q["url"])
            custom.showsRing = ["1", "true", "yes"].contains((q["ring"] ?? "").lowercased())
            let priority = q["priority"].flatMap { Int($0) } ?? 70
            var activity = IslandActivity(id: "api-" + id, kind: .custom, content: .custom(custom), priority: priority)
            if let ttl = q["ttl"].flatMap({ Double($0) }), ttl > 0 { activity.expiresAt = Date().addingTimeInterval(ttl) }
            if let u = custom.url { activity.openAction = .url(u) }
            center.upsert(activity)
            if ["1", "true", "yes"].contains((q["expanded"] ?? "").lowercased()) {
                center.forceExpanded(id: activity.id, for: q["duration"].flatMap { Double($0) } ?? 4)
            }

        case ("activity", "end"), ("activity", "stop"):
            if let id = q["id"] { center.end(id: "api-" + id) } else { center.end(kind: .custom) }

        case ("alert", _):
            var custom = CustomActivity(title: q["title"] ?? "Alert")
            custom.subtitle = q["subtitle"]
            custom.symbol = q["symbol"] ?? q["icon"] ?? "bell.fill"
            custom.tint = q["tint"] ?? q["color"] ?? "white"
            custom.trailingText = q["trailing"] ?? q["title"]
            custom.body = q["body"]
            custom.url = Self.safeLink(q["url"])
            let expanded = ["1", "true", "yes"].contains((q["expanded"] ?? "").lowercased())
            var activity = IslandActivity(id: "api-alert", kind: .custom, content: .custom(custom), priority: 85,
                                          presentation: expanded ? .expanded : .compact)
            if let u = custom.url { activity.openAction = .url(u) }
            center.showAlert(activity, duration: q["duration"].flatMap { Double($0) })

        case ("timer", ""), ("timer", "start"):
            let minutes = q["minutes"].flatMap { Double($0) } ?? 0
            let seconds = q["seconds"].flatMap { Double($0) } ?? 0
            let total = minutes * 60 + seconds
            if total > 0 { IslandTimer.shared.start(seconds: total, label: q["label"] ?? "Timer") }
        case ("timer", "pomodoro"):
            IslandTimer.shared.startPomodoro(work: (q["work"].flatMap { Double($0) } ?? 25) * 60,
                                             rest: (q["rest"].flatMap { Double($0) } ?? 5) * 60,
                                             cycles: q["cycles"].flatMap { Int($0) } ?? 4,
                                             longRest: (q["long"].flatMap { Double($0) } ?? 15) * 60)
        case ("timer", "cancel"), ("timer", "stop"):
            IslandTimer.shared.cancel()
        case ("timer", "pause"):
            IslandTimer.shared.pause()
        case ("timer", "resume"):
            IslandTimer.shared.resume()

        case ("stopwatch", ""), ("stopwatch", "start"):
            IslandStopwatch.shared.start()
        case ("stopwatch", "lap"):
            IslandStopwatch.shared.lap()
        case ("stopwatch", "stop"), ("stopwatch", "pause"):
            IslandStopwatch.shared.stop()
        case ("stopwatch", "reset"), ("stopwatch", "cancel"):
            IslandStopwatch.shared.reset()

        case ("shelf", "add"):
            if let p = q["path"] { ShelfStore.shared.add([URL(fileURLWithPath: (p as NSString).expandingTildeInPath)]) }
        case ("shelf", "clear"):
            ShelfStore.shared.clear()

        case ("home", let tab):
            // notchisland://home, notchisland://home/shelf, notchisland://home?tab=clipboard
            let wanted = (q["tab"] ?? tab).lowercased()
            if HomeSection(rawValue: wanted) != nil {
                center.open(.home(tab: wanted))
            } else {
                center.showHome()
            }
        case ("collapse", _):
            center.collapse()
        case ("settings", let pane):
            // notchisland://settings, notchisland://settings/island, notchisland://settings?pane=about
            SettingsWindow.open(SettingsSection.named(q["pane"] ?? pane))
        default:
            IslandLog.island.error("unknown notchisland URL: \(url.absoluteString, privacy: .private)")
        }
    }
}
