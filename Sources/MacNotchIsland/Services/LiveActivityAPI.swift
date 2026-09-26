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
///   notchisland://ask?title=Deploy%3F&detail=…&yes=Deploy&no=Wait&timeout=60&reply=/tmp/notchctl-ask.X/answer&token=…
///   notchisland://ask/cancel?token=…              (the token the question was put up with)
///   Lengths are numbers, or numbers with a unit: minutes=45, minutes=45m, seconds=90s, ttl=10m
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

    /// What a card's button does when it is pressed, decided at that moment.
    ///
    /// `actions(from:allowsShortcuts:)` reads "Let pushed cards run Shortcuts" when the card is
    /// pushed, and that alone was the whole check: a card pushed with a Shortcut while the
    /// switch was on went on running it after the switch was turned off, for as long as the
    /// card stayed up. So the switch is asked again here, as it is now, for every card a
    /// script pushed (`pushedPrefix`). The island's own cards carry commands, never a Shortcut
    /// somebody else named, and are not held to it.
    enum Press: Equatable {
        case command(IslandCommand)
        case link(URL)
        case shortcut(String)
        /// A Shortcut a pushed card names, with the switch off now: nothing is run, and the
        /// button is drawn as one that does nothing.
        case refused
        /// Nothing to do at all.
        case nothing
    }

    /// The id every card a script pushes carries in front of its own: `activity` and `alert`.
    static let pushedPrefix = "api-"

    /// The id of a card `activity` pushes: the prefix and the script's name for it, or "custom"
    /// for a card with no name, or a name of nothing but spaces.
    static func pushedID(_ raw: String?) -> String {
        pushedPrefix + (text(raw) ?? "custom")
    }

    /// The id of the alert a script pushes: the prefix alone. It was "api-alert", which is also
    /// the id `notchctl activity alert` gave its card, and the two wrote over each other — a
    /// clicked alert kept as an activity replaced the card, and ending the card took the alert.
    /// Every pushed card is the prefix and a name that is never nothing (`pushedID`), so none
    /// can take this one.
    static let alertID = pushedPrefix

    /// Pure: what pressing `action` on the card `activityID` does, with the switch as it is.
    /// The order is `CustomAction`'s: a command, then a link, then a Shortcut.
    static func press(_ action: CustomAction, activityID: String, allowsShortcuts: Bool) -> Press {
        if let command = action.command { return .command(command) }
        if let url = action.url { return .link(url) }
        guard let name = action.shortcut, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return .nothing }
        guard allowsShortcuts || !activityID.hasPrefix(pushedPrefix) else { return .refused }
        return .shortcut(name)
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
    /// minute is longer than any alert needs to be read. Read as `length` reads one, so "3s"
    /// is three seconds here as well.
    static func seconds(_ raw: String?) -> TimeInterval? {
        guard case .seconds(let value) = length(raw, per: 1), value > 0 else { return nil }
        return min(value, maxSeconds)
    }

    // MARK: - Lengths

    /// A length as a script wrote it.
    enum Length: Equatable {
        /// Not in the query at all: the command's own default applies.
        case absent
        /// A length, in seconds. Any sign; what a command does with one is its own business.
        case seconds(TimeInterval)
        /// In the query, and not a length: the command is refused, never run on a default.
        case unreadable

        /// The seconds, and nothing for a length that is absent or unreadable.
        var amount: TimeInterval {
            if case .seconds(let value) = self { return value }
            return 0
        }
    }

    /// The units a length may carry, in seconds. The minutes are every word the Actions field
    /// takes after a number (`TimerEntry.typedMinutes`), so "25m" and "25 min" mean the same in
    /// a script as they do there.
    static let unitWords: [String: TimeInterval] = [
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
    ]

    /// A length a script sent: a plain decimal number, optionally signed, and after it
    /// optionally one of `unitWords`. A bare number counts `unit` seconds each — 60 for
    /// `minutes=`, 1 for `seconds=` and `ttl=`.
    ///
    /// Every one of these was `Double(x) ?? default`: "45m" is not a `Double`, so `notchctl
    /// sleep 45m` set the default thirty minutes, `timer add 5m` added one, `--work 50m` gave
    /// twenty-five and `--ttl 10m` a card that never went — each with `notchctl` saying it had
    /// worked. And `Double` takes "1e300", "inf" and "0x1p9", none of which anybody means as a
    /// length. So only plain decimals are numbers here; anything else is `unreadable`, and the
    /// command is refused and logged. Pure, so the grammar is tested.
    static func length(_ raw: String?, per unit: TimeInterval) -> Length {
        guard let raw else { return .absent }
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let end = text.firstIndex { !($0.isASCII && ($0.isNumber || $0 == "." || $0 == "-")) } ?? text.endIndex
        let number = String(text[..<end])
        let word = text[end...].trimmingCharacters(in: .whitespaces)
        guard isPlainNumber(number), let value = Double(number),
              let scale = word.isEmpty ? Optional(unit) : unitWords[word] else { return .unreadable }
        let seconds = value * scale
        return seconds.isFinite ? .seconds(seconds) : .unreadable
    }

    /// Digits, with at most one point between digits, and a minus sign in front if anything.
    private static func isPlainNumber(_ text: String) -> Bool {
        let body = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// The longest timer a script may start, or add in one go: the day the Actions field
    /// allows (`TimerEntry.maxTypedMinutes`). `timer?minutes=1e300` was a timer, and its card
    /// brought the app down when it was read aloud (`IslandAccessibility.spokenDuration`).
    static let maxTimer: TimeInterval = TimeInterval(TimerEntry.maxTypedMinutes) * 60

    /// A length that is a timer: more than nothing, and no more than `maxTimer`. Nil otherwise.
    static func timerLength(_ seconds: TimeInterval) -> TimeInterval? {
        seconds.isFinite && seconds > 0 && seconds <= maxTimer ? seconds : nil
    }

    /// A timer's length from one field: `fallback` when it is not there, and nil when it is and
    /// cannot be read or is not a timer.
    static func timer(_ raw: String?, per unit: TimeInterval, absent fallback: TimeInterval) -> TimeInterval? {
        switch length(raw, per: unit) {
        case .absent: return fallback
        case .seconds(let value): return timerLength(value)
        case .unreadable: return nil
        }
    }

    /// `timer?minutes=5&seconds=30`: the two added up. Nil when either is there and cannot be
    /// read, or the sum is not a timer — nothing at all included, which starts nothing.
    static func timerStart(minutes: String?, seconds: String?) -> TimeInterval? {
        let m = length(minutes, per: 60), s = length(seconds, per: 1)
        guard m != .unreadable, s != .unreadable else { return nil }
        return timerLength(m.amount + s.amount)
    }

    /// `timer/add?minutes=2`: a minute when neither is there, as it always was; otherwise the
    /// two added up, a negative sum taking time off (`IslandTimer.add(seconds:id:)`). Nil when
    /// either cannot be read, or the sum is nothing or more than a day either way. The minute
    /// is no longer added to `seconds=30` as well, which made it ninety.
    static func timerAdd(minutes: String?, seconds: String?) -> TimeInterval? {
        let m = length(minutes, per: 60), s = length(seconds, per: 1)
        guard m != .unreadable, s != .unreadable else { return nil }
        if m == .absent && s == .absent { return IslandTimer.addStep }
        let total = m.amount + s.amount
        return total.isFinite && total != 0 && abs(total) <= maxTimer ? total : nil
    }

    /// `sleep?minutes=45`, thirty minutes when it says nothing.
    static let defaultSleep: TimeInterval = 30 * 60

    /// A Pomodoro run as a script asked for it.
    struct PomodoroRequest: Equatable {
        var work: TimeInterval
        var rest: TimeInterval
        var longRest: TimeInterval
        var cycles: Int
    }

    /// `timer/pomodoro?work=50&rest=10&cycles=3&long=20`, each in minutes unless it says
    /// otherwise, and the usual 25, 5, 4 and 15 for whatever it leaves out. Nil when any of
    /// them is there and is not what it should be: a length that is not a timer, or a count of
    /// cycles that is not a whole number above nought.
    static func pomodoro(_ q: [String: String]) -> PomodoroRequest? {
        guard let work = timer(q["work"], per: 60, absent: 25 * 60),
              let rest = timer(q["rest"], per: 60, absent: 5 * 60),
              let longRest = timer(q["long"], per: 60, absent: 15 * 60) else { return nil }
        var cycles = 4
        if let raw = q["cycles"] {
            guard let count = Int(raw.trimmingCharacters(in: .whitespaces)), count > 0 else { return nil }
            cycles = count
        }
        return PomodoroRequest(work: work, rest: rest, longRest: longRest, cycles: cycles)
    }

    /// `ttl=`: how long a card stays, in seconds unless it says otherwise. Absent is a card that
    /// stays until it is ended; anything there that is not a length above nought is unreadable,
    /// and the card is refused rather than left up for ever.
    static func ttl(_ raw: String?) -> Length {
        let read = length(raw, per: 1)
        if case .seconds(let value) = read, value <= 0 { return .unreadable }
        return read
    }

    /// What a refused command was sent, for the log.
    private static func said(_ q: [String: String], _ keys: String...) -> String {
        keys.compactMap { key in q[key].map { "\(key)=\($0)" } }.joined(separator: " ")
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
            // A card asked to go in "10m" was a card that never went: the length is read as
            // `length` reads one, and one that cannot be read is no card at all.
            let ttl = Self.ttl(q["ttl"])
            if ttl == .unreadable {
                IslandLog.island.error("activity: \(Self.said(q, "ttl"), privacy: .public) is not a length")
                return
            }
            var custom = CustomActivity(title: Self.text(q["title"]) ?? "Activity")
            custom.subtitle = q["subtitle"]
            custom.symbol = Self.symbol(q["symbol"] ?? q["icon"], fallback: "app.fill")
            custom.tint = q["tint"] ?? q["color"] ?? "white"
            custom.progress = q["progress"].flatMap { Double($0) }.map { min(1, max(0, $0)) }
            custom.trailingText = q["trailing"]
            // "body=" is no body. Kept as "", the card was sized for a line the view does not
            // draw (`cardHeight`), and 24 pt of black hung under it.
            custom.body = Self.text(q["body"])
            custom.url = Self.safeLink(q["url"])
            custom.showsRing = ["1", "true", "yes"].contains((q["ring"] ?? "").lowercased())
            custom.actions = Self.actions(from: q, allowsShortcuts: Preferences.shared.apiShortcutsEnabled)
            let priority = Self.priority(q["priority"]) ?? 70
            var activity = IslandActivity(id: Self.pushedID(q["id"]), kind: .custom, content: .custom(custom), priority: priority)
            if case .seconds(let seconds) = ttl { activity.expiresAt = Date().addingTimeInterval(seconds) }
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
                center.end(id: Self.pushedID(id))
            } else {
                for a in center.activities where a.id.hasPrefix(Self.pushedPrefix) { center.end(id: a.id) }
            }

        case ("alert", _):
            let title = Self.text(q["title"])
            var custom = CustomActivity(title: title ?? "Alert")
            custom.subtitle = q["subtitle"]
            custom.symbol = Self.symbol(q["symbol"] ?? q["icon"], fallback: "bell.fill")
            custom.tint = q["tint"] ?? q["color"] ?? "white"
            custom.trailingText = q["trailing"] ?? title
            custom.body = Self.text(q["body"])
            custom.url = Self.safeLink(q["url"])
            custom.actions = Self.actions(from: q, allowsShortcuts: Preferences.shared.apiShortcutsEnabled)
            let expanded = ["1", "true", "yes"].contains((q["expanded"] ?? "").lowercased())
            var activity = IslandActivity(id: Self.alertID, kind: .custom, content: .custom(custom), priority: 85,
                                          presentation: expanded ? .expanded : .compact)
            if let u = custom.url { activity.openAction = .url(u) }
            // A script's own figure is taken as it stands. The alert slider scales the island's
            // alerts against each other; it is not a licence to turn "three seconds" into ten.
            let seconds = Self.seconds(q["duration"])
            if let raw = q["duration"], seconds == nil {
                // Shown for its usual time rather than refused: the alert is the point, and a
                // script that misspelt the length still meant to say something. Said in the log.
                IslandLog.island.error("alert: duration=\(raw, privacy: .public) is not a length; shown for the usual time")
            }
            center.showAlert(activity, duration: seconds, exact: seconds != nil)

        // Every length below is read by `length`, and one that is there and cannot be read, or
        // is not a timer, is refused and logged rather than run on a default.
        case ("timer", ""), ("timer", "start"):
            guard let total = Self.timerStart(minutes: q["minutes"], seconds: q["seconds"]) else {
                IslandLog.island.error("timer: \(Self.said(q, "minutes", "seconds"), privacy: .public) is not a timer of up to a day")
                return
            }
            IslandTimer.shared.start(seconds: total, label: q["label"] ?? "Timer")
        case ("timer", "pomodoro"):
            guard let run = Self.pomodoro(q) else {
                IslandLog.island.error("pomodoro: \(Self.said(q, "work", "rest", "long", "cycles"), privacy: .public) is not a run")
                return
            }
            IslandTimer.shared.startPomodoro(work: run.work, rest: run.rest, cycles: run.cycles, longRest: run.longRest)
        case ("timer", "add"):
            guard let change = Self.timerAdd(minutes: q["minutes"], seconds: q["seconds"]) else {
                IslandLog.island.error("timer/add: \(Self.said(q, "minutes", "seconds"), privacy: .public) is not a length of up to a day")
                return
            }
            IslandTimer.shared.add(seconds: change)
        case ("timer", "sleep"), ("sleep", ""), ("sleep", "start"):
            guard let duration = Self.timer(q["minutes"], per: 60, absent: Self.defaultSleep) else {
                IslandLog.island.error("sleep: \(Self.said(q, "minutes"), privacy: .public) is not a timer of up to a day")
                return
            }
            IslandTimer.shared.startSleep(seconds: duration)
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
        case ("ask", "cancel"):
            // `notchctl ask` interrupted: the question it put is taken down unanswered, so it
            // does not hold the island, and Control-Y and Control-N, for the rest of its time.
            // Only with the token the script put the question up with; see `IslandAsk.cancel`.
            guard let token = q["token"] else {
                IslandLog.island.error("ask/cancel: no token")
                return
            }
            IslandAsk.shared.cancel(token: token)
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
