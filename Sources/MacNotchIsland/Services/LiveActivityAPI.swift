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
///   notchisland://alarm?at=07:30&label=Wake       notchisland://alarm/cancel[?id=…]
///   notchisland://stopwatch | stopwatch/lap | stopwatch/stop | stopwatch/reset
///   notchisland://shelf/add?path=/Users/me/file.pdf   notchisland://shelf/clear
///   notchisland://ask?title=Deploy%3F&detail=…&yes=Deploy&no=Wait&timeout=60&reply=/tmp/notchctl-ask.X/answer
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

    // MARK: - The rest of the query, held to what the island can draw

    /// The longest a script may keep an alert, or a card forced open, on the island.
    static let maxSeconds: TimeInterval = 60

    /// A length in seconds, or nothing. `Double` reads "inf", "nan" and "-3" as numbers, and
    /// each of them is a way to put something up for ever or take it down on arrival; a
    /// minute is longer than any alert needs to be read.
    static func seconds(_ raw: String?) -> TimeInterval? {
        raw.flatMap { Double($0) }.flatMap { $0.isFinite && $0 > 0 ? min($0, maxSeconds) : nil }
    }

    /// A card's rank, kept under a call's. Anything on this Mac can push a card, and a call is
    /// 100: a card that asked for more would sit on top of the one thing that cannot wait.
    static func priority(_ raw: String?) -> Int? {
        raw.flatMap { Int($0) }.map { min(99, max(0, $0)) }
    }

    /// A value with something in it, or nothing: a title of nothing but spaces is a card with
    /// nothing to say, and gets the default one instead.
    static func text(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    /// The glyph asked for when SF Symbols has one by that name, and the card's own otherwise:
    /// a name that is not a symbol draws nothing at all, and leaves a hole in the card.
    static func symbol(_ raw: String?, fallback: String,
                       exists: (String) -> Bool = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }) -> String {
        guard let raw, exists(raw) else { return fallback }
        return raw
    }

    /// When `alarm?at=` rings, read with the rule the Actions field reads a typed time with
    /// (`TimerEntry.parse`), so "07:30", "7:30pm" and "19:30" mean the same here as there. A
    /// bare number is minutes to that rule and so not a time; it, and anything else, is nil.
    static func alarmDate(_ raw: String?, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let raw, case .alarm(let date)? = TimerEntry.parse(raw, now: now, calendar: calendar) else { return nil }
        return date
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
            var custom = CustomActivity(title: Self.text(q["title"]) ?? "Activity")
            custom.subtitle = q["subtitle"]
            custom.symbol = Self.symbol(q["symbol"] ?? q["icon"], fallback: "app.fill")
            custom.tint = q["tint"] ?? q["color"] ?? "white"
            custom.progress = q["progress"].flatMap { Double($0) }.map { min(1, max(0, $0)) }
            custom.trailingText = q["trailing"]
            custom.body = q["body"]
            custom.url = Self.safeLink(q["url"])
            custom.showsRing = ["1", "true", "yes"].contains((q["ring"] ?? "").lowercased())
            custom.actions = Self.actions(from: q, allowsShortcuts: Preferences.shared.apiShortcutsEnabled)
            let priority = Self.priority(q["priority"]) ?? 70
            var activity = IslandActivity(id: "api-" + id, kind: .custom, content: .custom(custom), priority: priority)
            if let ttl = q["ttl"].flatMap({ Double($0) }), ttl > 0 { activity.expiresAt = Date().addingTimeInterval(ttl) }
            if let u = custom.url { activity.openAction = .url(u) }
            center.upsert(activity)
            if ["1", "true", "yes"].contains((q["expanded"] ?? "").lowercased()) {
                center.forceExpanded(id: activity.id, for: Self.seconds(q["duration"]) ?? 4)
            }

        case ("activity", "end"), ("activity", "stop"):
            // Without an id, every card a script pushed — and only those. The island's own
            // activities are `.custom` too (the screen recording's, with its Stop button), and
            // ending by kind took that one down while `screencapture` went on recording.
            if let id = q["id"] {
                center.end(id: "api-" + id)
            } else {
                for a in center.activities where a.id.hasPrefix("api-") { center.end(id: a.id) }
            }

        case ("alert", _):
            let title = Self.text(q["title"])
            var custom = CustomActivity(title: title ?? "Alert")
            custom.subtitle = q["subtitle"]
            custom.symbol = Self.symbol(q["symbol"] ?? q["icon"], fallback: "bell.fill")
            custom.tint = q["tint"] ?? q["color"] ?? "white"
            custom.trailingText = q["trailing"] ?? title
            custom.body = q["body"]
            custom.url = Self.safeLink(q["url"])
            custom.actions = Self.actions(from: q, allowsShortcuts: Preferences.shared.apiShortcutsEnabled)
            let expanded = ["1", "true", "yes"].contains((q["expanded"] ?? "").lowercased())
            var activity = IslandActivity(id: "api-alert", kind: .custom, content: .custom(custom), priority: 85,
                                          presentation: expanded ? .expanded : .compact)
            if let u = custom.url { activity.openAction = .url(u) }
            // A script's own figure is taken as it stands. The alert slider scales the island's
            // alerts against each other; it is not a licence to turn "three seconds" into ten.
            let seconds = Self.seconds(q["duration"])
            center.showAlert(activity, duration: seconds, exact: seconds != nil)

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

        case ("alarm", ""), ("alarm", "set"), ("alarm", "start"):
            // notchisland://alarm?at=07:30&label=Wake — the next time the clock reads it.
            guard let date = Self.alarmDate(q["at"] ?? q["time"]) else {
                IslandLog.island.error("alarm: \(q["at"] ?? q["time"] ?? "", privacy: .public) is not a time")
                return
            }
            IslandTimer.shared.setAlarm(at: date, label: Self.text(q["label"]))
        case ("alarm", "cancel"), ("alarm", "stop"):
            // By id, by the time it was set for, or every one of them.
            if let id = q["id"] {
                IslandTimer.shared.cancelAlarm(id: id)
            } else if let raw = q["at"] ?? q["time"] {
                let wanted = TimerEntry.clockTime(raw.trimmingCharacters(in: .whitespaces).lowercased())
                let calendar = Calendar.current
                // The list this walks is empty until the last run's alarms are read back, and a
                // URL that launched the app is handled before launch reads them.
                IslandTimer.shared.loadAlarmsIfNeeded()
                for alarm in IslandTimer.shared.alarms {
                    let parts = calendar.dateComponents([.hour, .minute], from: alarm.fireDate)
                    if parts.hour == wanted?.hour, parts.minute == wanted?.minute { IslandTimer.shared.cancelAlarm(id: alarm.id) }
                }
            } else {
                IslandTimer.shared.cancelAllAlarms()
            }

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

        case ("ask", ""):
            // A yes-or-no question held on the island until it is answered, with the answer
            // written to `reply`; `notchctl ask` waits on that file. See `IslandAsk`.
            IslandAsk.shared.handle(query: q)
        case ("ask", "answer"):
            // The card's own buttons, which carry the question's token. Anything without it is
            // somebody else's guess at an answer, and answers nothing.
            guard let token = q["token"], let answer = q["answer"].flatMap(AskAnswer.init(rawValue:)) else {
                IslandLog.island.error("ask/answer: no token or no answer")
                return
            }
            IslandAsk.shared.answer(answer, token: token)

        case ("home", let tab):
            // notchisland://home, notchisland://home/shelf, notchisland://home?tab=clipboard
            let wanted = (q["tab"] ?? tab).lowercased()
            // A section the user has switched off is not in the switcher, so opening the
            // panel on it would leave the band with nothing lit and the arrows stepping out
            // of a view they cannot step back into. The panel opens where it usually does,
            // and the log says why, since nothing else here can. The switcher's own rule, so a
            // Controls section kept for the rail's overflow can be reached here too.
            if let section = HomeSection(rawValue: wanted), section.isShown(Preferences.shared) {
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
