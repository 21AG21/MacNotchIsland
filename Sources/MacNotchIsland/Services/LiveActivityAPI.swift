import AppKit

/// Third-party Live Activities and alerts through the `notchisland://` URL scheme
/// (works from Shortcuts' "Open URLs", scripts, CI hooks) and a distributed notification.
///
///   notchisland://activity?id=build&title=Building&subtitle=xcodebuild&symbol=hammer.fill&tint=blue&progress=0.4&trailing=40%25&ttl=600&expanded=1&ring=1&url=https://…
///   …&action=Retry&action_url=https://ci/retry&action2=Deploy&action2_shortcut=Ship%20it
///   notchisland://activity/end?id=build
///   notchisland://alert?title=Deployed&symbol=checkmark.circle.fill&tint=green&duration=3
///   notchisland://timer?minutes=5&label=Tea       notchisland://timer/cancel | pause | resume
///   notchisland://timer/add?minutes=1
///   notchisland://timer/pomodoro?work=25&rest=5&cycles=4&long=15
///   notchisland://sleep?minutes=30                notchisland://sleep/cancel
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

    /// At most two buttons, because that is what a card has room for beside its text.
    static let maxActions = 2

    /// The buttons a script asked for, read out of the query.
    ///
    ///   &action=Retry&action_url=https://ci.example/retry
    ///   &action2=Run%20it&action2_shortcut=Deploy%20staging&action2_symbol=play.fill
    ///
    /// A button with no title, or with nowhere to go, is dropped rather than drawn as
    /// something that does nothing. A link is held to the same three schemes every other link
    /// a script pushes is: a button that opened `file:` or another app's scheme would be a way
    /// to make somebody click on something they were never shown.
    ///
    /// And a named Shortcut is held to more than that, because it is worse. The link rule was
    /// written to stop a card reaching another app's scheme, and then the field right beside
    /// it handed a name straight to `shortcuts run`, which is a shell script by another name.
    /// Anything on this Mac can push a card; a card is drawn in the app's own hand, so its
    /// button reads as the island asking, and "Update available / Install" is a sentence
    /// anybody would click. So a pushed card may only name a Shortcut where the user has
    /// said outside cards may — see `Preferences.apiShortcutsEnabled`, which is off.
    ///
    /// Pure, so the rules can be tested without a URL to open or a Shortcut to run.
    static func actions(from q: [String: String], allowsShortcuts: Bool) -> [CustomAction] {
        (1...maxActions).compactMap { index in
            let key = index == 1 ? "action" : "action\(index)"
            guard let title = q[key]?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
            let action = CustomAction(title: title,
                                      symbol: q[key + "_symbol"],
                                      url: safeLink(q[key + "_url"]),
                                      shortcut: allowsShortcuts ? q[key + "_shortcut"] : nil)
            return action.isUsable ? action : nil
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
            custom.actions = Self.actions(from: q, allowsShortcuts: Preferences.shared.apiShortcutsEnabled)
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
            custom.actions = Self.actions(from: q, allowsShortcuts: Preferences.shared.apiShortcutsEnabled)
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
        case ("timer", "add"):
            let minutes = q["minutes"].flatMap { Double($0) } ?? 1
            let seconds = q["seconds"].flatMap { Double($0) } ?? 0
            IslandTimer.shared.add(seconds: minutes * 60 + seconds)
        case ("timer", "sleep"), ("sleep", ""), ("sleep", "start"):
            let minutes = q["minutes"].flatMap { Double($0) } ?? 30
            IslandTimer.shared.startSleep(seconds: minutes * 60)
        case ("sleep", "cancel"), ("sleep", "stop"):
            IslandTimer.shared.cancelSleep()
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
            // A section the user has switched off is not in the switcher, so opening the
            // panel on it would leave the band with nothing lit and the arrows stepping out
            // of a view they cannot step back into. The panel opens where it usually does,
            // and the log says why, since nothing else here can.
            if let section = HomeSection(rawValue: wanted), section.isEnabled(Preferences.shared) {
                center.open(.home(tab: wanted))
            } else {
                if !wanted.isEmpty {
                    IslandLog.island.notice("home: \(wanted, privacy: .public) is not a section that is switched on")
                }
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
