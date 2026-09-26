import AppKit
import Combine
import UserNotifications

/// One countdown owned by `IslandTimer`. iOS runs several at once: whichever finishes soonest
/// takes the island and the others fall back to the minimal bubble.
/// What a timer does when it rings, beyond ringing. A sleep timer is a countdown whose
/// whole point is what happens at the end of it.
enum TimerFinish: Equatable {
    case none
    /// Stop whatever is playing — the thing everybody sets a timer on a phone for at night.
    case pausePlayback
}

struct TimerEntry: Identifiable, Equatable {
    let id: String
    var label: String
    var state: TimerState
    var whenDone: TimerFinish = .none
    /// Higher wins the island. The soonest-to-finish timer sits one point above the rest.
    var priority: Int = 90
    var createdAt: Date = Date()
}

/// One phase of a Pomodoro run: "Focus 2/4", then "Break 2/4", with a long break every
/// few sessions like the iOS timers people build for this.
struct PomodoroPhase: Equatable {
    enum Kind: Equatable { case focus, rest, longRest }

    var kind: Kind
    /// 1-based session number.
    var cycle: Int
    var cycles: Int
    var work: TimeInterval
    var rest: TimeInterval
    var longRest: TimeInterval = 15 * 60
    /// A long break replaces the short one after every Nth focus session.
    var longBreakEvery: Int = 4

    var duration: TimeInterval {
        switch kind {
        case .focus: return work
        case .rest: return rest
        case .longRest: return longRest
        }
    }

    /// Sentence case, like the Clock app.
    var name: String {
        switch kind {
        case .focus: return "Focus"
        case .rest: return "Break"
        case .longRest: return "Long break"
        }
    }

    var isBreak: Bool { kind != .focus }
    var label: String { "\(name) \(cycle)/\(cycles)" }
}

/// The island's countdown timers, presented like the Clock app's Live Activity.
///
/// Several timers can run at once — each one is its own live activity, so the soonest to
/// finish owns the island and the next one becomes the bubble. The no-argument
/// `start` / `pause` / `resume` / `cancel` / `state` API keeps working and always addresses
/// the *primary* timer: the one currently first by priority.
final class IslandTimer: ObservableObject {
    static let shared = IslandTimer()

    /// Every timer, oldest first.
    @Published private(set) var timers: [TimerEntry] = []
    /// The phase of the Pomodoro run, when one is going.
    @Published private(set) var pomodoro: PomodoroPhase?
    /// Alarms waiting for their time, soonest first. Not live activities while they wait, see
    /// `IslandAlarm`; each becomes a timer that has rung when its time comes.
    @Published private(set) var alarms: [IslandAlarm] = []

    /// Where the alarms are written down so they outlive a relaunch. Timers are not kept —
    /// a countdown is minutes long and its moment has passed by the time the app is back —
    /// but an alarm is set for tomorrow morning, across an update or a restart. Swapped for a
    /// scratch suite by the tests.
    var alarmDefaults: UserDefaults = .standard
    static let alarmsKey = "pendingAlarms"
    /// The card that says an alarm is set, and the one that says one was missed.
    static let alarmSetAlertID = "alarm-set"
    static let alarmMissedAlertID = "alarm-missed"
    /// An alarm noticed this late — the Mac asleep at its time, the app relaunched — still
    /// rings; any later and it is reported as missed, see `IslandAlarm.triage`.
    static let missedGrace: TimeInterval = 10 * 60
    /// The longest the alarm check sleeps between looks. Waking from sleep and the clock being
    /// set are heard as they happen; this is the net under both.
    static let alarmCheckCeiling: TimeInterval = 60
    /// What Snooze gives, the nine minutes every bedside clock has given since the 1950s.
    static let snoozeInterval: TimeInterval = 9 * 60
    private var alarmCheck: Timer?
    private var alarmObservers: [NSObjectProtocol] = []
    /// Missed alarms whose report waits for somebody at the Mac, see `missedWaitsForUnlock`,
    /// and what is listening for them.
    private var missedAtUnlock: [IslandAlarm] = []
    private var unlockObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// Whether the last run's alarms have been read back yet, see `restoreAlarms`.
    private var alarmsLoaded = false

    /// The time on the clock an alarm was set for, kept beside it by id: an alarm is "the next
    /// time the clock reads 7:30", and its `fireDate` is only where that fell in the zone it
    /// was set in. A snooze has none — nine minutes are nine minutes wherever the Mac is.
    struct AlarmClock: Codable, Equatable {
        var hour: Int
        var minute: Int
    }
    static let alarmClocksKey = "pendingAlarmClocks"
    /// The time zone the alarms' `fireDate`s were worked out in, written down with them.
    static let alarmZoneKey = "pendingAlarmsTimeZone"
    private var alarmClocks: [String: AlarmClock] = [:]
    /// The zone `alarms` are in, by identifier; nil until something has looked.
    private var alarmsZone: String?

    /// iOS keeps the island readable by showing a couple of timers; four is our ceiling.
    static let maxTimers = 4
    private static let basePriority = 90
    /// Height of one row in the expanded view's list of the other timers. As tall as the
    /// target of the button that cancels it: at 22 the 18 pt cross took its click in its own
    /// 18, and a 24 pt target in a 22 pt row would have lain over the next row's.
    static let rowHeight: CGFloat = 24

    private var ticker: Timer?
    /// What makes the ticker look again straight away, see `watchTheClockForTimers`.
    private var tickerObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var lastDuration: TimeInterval = 300
    private var lastLabel = "Timer"
    /// Which timer (if any) the Pomodoro run is driving.
    private(set) var pomodoroTimerID: String?
    /// Bumped whenever a Pomodoro starts or stops, so a queued phase change from an older
    /// run can tell that it is stale.
    private var pomodoroGeneration = 0
    private var askedForNotifications = false

    private init() {}

    // MARK: - The primary timer

    /// Timers in island order: highest priority first, newest first among equals — the same
    /// rule `ActivityCenter` sorts live activities by.
    var sortedTimers: [TimerEntry] {
        timers.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.createdAt > b.createdAt
        }
    }

    /// The timer that owns the island right now.
    var primary: TimerEntry? { sortedTimers.first }

    /// The primary timer's state, `nil` when nothing is running.
    var state: TimerState? { primary?.state }

    /// The other timers, most recent first — the order the expanded view stacks them in.
    var secondaryTimers: [TimerEntry] {
        guard let primaryID = primary?.id else { return [] }
        return timers.filter { $0.id != primaryID }.sorted { $0.createdAt > $1.createdAt }
    }

    var isPomodoroRunning: Bool { pomodoro != nil }

    func entry(id: String) -> TimerEntry? { timers.first { $0.id == id } }

    /// Extra height the expanded timer view needs for the rows listing the other timers.
    static var extraRowsHeight: CGFloat {
        CGFloat(min(max(shared.timers.count - 1, 0), 2)) * rowHeight
    }

    // MARK: - Starting

    /// A length the island will count down: finite and above nought. Where a script may say
    /// how long, the URL scheme holds it to a day as well (`LiveActivityAPI.timerLength`).
    static func isCountable(_ seconds: TimeInterval) -> Bool { seconds.isFinite && seconds > 0 }

    func start(seconds: TimeInterval, label: String = "Timer") {
        guard Self.isCountable(seconds) else { return }
        lastDuration = seconds
        lastLabel = label
        _ = add(seconds: seconds, label: label)
    }

    /// The last timer started, started again as another one. Nothing on screen asks for this
    /// any more: a card or a menu is always about one timer, and repeats that one, see
    /// `repeatTimer(id:)`.
    func repeatLast() {
        start(seconds: lastDuration, label: lastLabel)
    }

    /// This timer again from the top: its own name and its own length, in its own place on
    /// the island.
    ///
    /// Repeat on a card used to be `repeatLast`, the last timer *started* — with two running,
    /// as often as not the other one. The pasta rang, Repeat set the tea going a second time,
    /// and the card went on saying the pasta was done, because a timer that has rung sorts
    /// first. It restarts where it is instead, under the same id, so the card that rang is the
    /// card that counts down again. The length is the one the ring was measuring, a minute
    /// added included.
    ///
    /// A phase of a Pomodoro run goes again as that phase, and the run carries on after it;
    /// the change to the next phase that was waiting is dropped. An alarm has no length to
    /// repeat — Snooze is its second go — and is left alone.
    func repeatTimer(id: String, now: Date = Date()) {
        guard let i = index(of: id), !timers[i].state.isAlarm else { return }
        if id == pomodoroTimerID, let phase = pomodoro {
            pomodoroGeneration &+= 1
            begin(phase)
            return
        }
        let label = timers[i].label
        let total = max(timers[i].state.total, Self.minimumRemaining)
        timers[i].state = TimerState(label: label, total: total, endDate: now.addingTimeInterval(total))
        // A new start, so the tidy-up queued for the ring that came before finds a different
        // timer here and leaves it alone.
        timers[i].createdAt = now
        lastDuration = total
        lastLabel = label
        reprioritize()
        publishAll()
        syncTicker()
    }

    /// The label a sleep timer wears, and the one the card shows.
    static let sleepLabel = "Sleep"

    /// Stop playing in so many seconds. One at a time: asking for another moves the old one
    /// rather than leaving two countdowns racing to silence the same track.
    func startSleep(seconds: TimeInterval) {
        guard Self.isCountable(seconds) else { return }
        cancelSleep()
        guard let id = add(seconds: seconds, label: Self.sleepLabel) else { return }
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[index].whenDone = .pausePlayback
        publishAll()
    }

    /// The sleep timer, if one is counting down.
    var sleepTimer: TimerEntry? {
        timers.first { $0.whenDone == .pausePlayback && !$0.state.isFinished }
    }

    func cancelSleep() {
        guard let entry = sleepTimer else { return }
        cancel(id: entry.id)
    }

    /// Adds a timer and returns its activity id, or `nil` when the island is already full.
    @discardableResult
    private func add(seconds: TimeInterval, label: String) -> String? {
        // A finished timer nobody dismissed yields its slot to a fresh one.
        if timers.count >= Self.maxTimers, let stale = timers.first(where: { $0.state.isFinished }) {
            remove(id: stale.id)
        }
        guard timers.count < Self.maxTimers else { return nil }
        let id = freeID()
        timers.append(TimerEntry(id: id, label: label,
                                 state: TimerState(label: label, total: seconds,
                                                   endDate: Date().addingTimeInterval(seconds)),
                                 priority: Self.basePriority, createdAt: Date()))
        reprioritize()
        ActivityCenter.shared.dismissAlert()
        publishAll()
        syncTicker()
        return id
    }

    /// The first timer keeps the plain "timer" id — scripts and the URL scheme address it —
    /// and every extra one gets a unique one.
    private func freeID() -> String {
        if !timers.contains(where: { $0.id == "timer" }) { return "timer" }
        return "timer-" + UUID().uuidString
    }

    // MARK: - Primary-timer controls

    /// For scripts, the URL scheme and the menu bar, which name no timer. Anything drawn for
    /// one timer — its card, its menu — uses the `id:` forms below, or it acts on whichever
    /// timer happens to be first while showing another.
    func pause() {
        guard let id = primary?.id else { return }
        pause(id: id)
    }

    func resume() {
        guard let id = primary?.id else { return }
        resume(id: id)
    }

    func cancel() {
        guard let id = primary?.id else { return }
        cancel(id: id)
    }

    func add(seconds: TimeInterval) {
        guard let id = primary?.id else { return }
        add(seconds: seconds, id: id)
    }

    // MARK: - Per-timer controls

    func pause(id: String) {
        guard let i = index(of: id) else { return }
        var s = timers[i].state
        guard !s.isFinished, !s.isPaused else { return }
        s.pausedRemaining = s.remaining(at: Date())
        timers[i].state = s
        reprioritize()
        publishAll()
        // Nothing changes while paused; stop ticking rather than waking up every second to
        // compare a remaining time that never moves.
        syncTicker()
    }

    func resume(id: String) {
        guard let i = index(of: id) else { return }
        var s = timers[i].state
        guard let remaining = s.pausedRemaining else { return }
        s.endDate = Date().addingTimeInterval(remaining)
        s.pausedRemaining = nil
        timers[i].state = s
        reprioritize()
        publishAll()
        syncTicker()
    }

    /// Another minute, the way you ask a smart speaker for one. A running timer's end moves
    /// out; a paused one has more waiting for it when it resumes. The total moves with it, so
    /// the ring keeps meaning "how much of this timer is left" rather than jumping backwards.
    ///
    /// A negative figure takes time off instead — a minute less, in `addStep`s like the minute
    /// more — and never so much that the timer rings on the spot: at least
    /// `minimumRemaining` is left, so taking off more than there is lands on one second to go,
    /// and a timer with a second or less left is not shortened at all. The label and the rest
    /// of the timer stay as they were.
    ///
    /// A timer that has already rung is neither extended nor shortened: there is nothing left
    /// to add to, and the card offers Repeat for that instead.
    func add(seconds: TimeInterval, id: String, now: Date = Date()) {
        guard seconds.isFinite, seconds != 0, let i = index(of: id) else { return }
        var s = timers[i].state
        guard !s.isFinished else { return }
        let change = Self.adjustment(seconds, remaining: s.remaining(at: now))
        guard change != 0 else { return }
        // The total moves with the end, so the ring keeps its place either way.
        s.total = max(s.total + change, Self.minimumRemaining)
        if let paused = s.pausedRemaining {
            s.pausedRemaining = paused + change
        } else {
            s.endDate = s.endDate.addingTimeInterval(change)
        }
        timers[i].state = s
        reprioritize()
        publishAll()
        syncTicker()
    }

    /// What one press of "another minute" adds, and one press of "a minute less" takes off.
    static let addStep: TimeInterval = 60

    /// The least a shortened timer is left with.
    static let minimumRemaining: TimeInterval = 1

    /// How far a timer with `remaining` to go actually moves when asked to move by `seconds`:
    /// all of it forwards, and backwards only as far as leaves `minimumRemaining`. Zero is
    /// nothing to do. Pure, so the floor is tested.
    static func adjustment(_ seconds: TimeInterval, remaining: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        if seconds >= 0 { return seconds }
        return max(seconds, min(0, minimumRemaining - remaining))
    }

    func cancel(id: String) {
        // Cancelling the Pomodoro's timer ends the whole run, not just this phase.
        if id == pomodoroTimerID { stopPomodoro() }
        remove(id: id)
    }

    /// Stop every timer and any Pomodoro run.
    func cancelAll() {
        stopPomodoro()
        for t in timers { ActivityCenter.shared.end(id: t.id) }
        timers.removeAll()
        syncTicker()
    }

    /// Marks a timer as rung without waiting out its countdown. Used by the test suite.
    func finishForTesting(id: String) {
        guard let i = index(of: id) else { return }
        timers[i].state.isFinished = true
        publishAll()
    }

    private func remove(id: String) {
        guard let i = index(of: id) else { return }
        timers.remove(at: i)
        ActivityCenter.shared.end(id: id)
        if reprioritize() { publishAll() }
        syncTicker()
    }

    private func index(of id: String) -> Int? { timers.firstIndex { $0.id == id } }

    /// Give the soonest-to-finish timer the top priority, so the compact island (and the
    /// bubble behind it) show the one that matters next. A ringing timer comes first, and
    /// the newest wins ties, which is what starting a timer feels like.
    @discardableResult
    private func reprioritize() -> Bool {
        let now = Date()
        let order = timers.sorted { a, b in
            if a.state.isFinished != b.state.isFinished { return a.state.isFinished }
            let ra = a.state.remaining(at: now), rb = b.state.remaining(at: now)
            if ra != rb { return ra < rb }
            return a.createdAt > b.createdAt
        }
        var changed = false
        for (rank, entry) in order.enumerated() {
            guard let i = index(of: entry.id) else { continue }
            let priority = Self.basePriority + (rank == 0 ? 1 : 0)
            if timers[i].priority != priority {
                timers[i].priority = priority
                changed = true
            }
        }
        return changed
    }

    // MARK: - Pomodoro

    /// Focus / break cycles in a single timer: the label alternates, a long break lands after
    /// every fourth session, and the live activity rolls straight into the next phase when one
    /// ends. Nothing is persisted.
    func startPomodoro(work: TimeInterval = 25 * 60, rest: TimeInterval = 5 * 60, cycles: Int = 4,
                       longRest: TimeInterval = 15 * 60, longBreakEvery: Int = 4) {
        guard Self.isCountable(work), Self.isCountable(rest), longRest.isFinite, cycles > 0 else { return }
        if let id = pomodoroTimerID { remove(id: id) }
        stopPomodoro()
        begin(PomodoroPhase(kind: .focus, cycle: 1, cycles: cycles, work: work, rest: rest,
                            longRest: max(rest, longRest), longBreakEvery: max(1, longBreakEvery)))
    }

    /// Focus → Break → Focus …, with a long break after every `longBreakEvery`th session,
    /// ending after the last cycle's break. Pure, so the sequencing can be checked without
    /// waiting on a clock.
    static func nextPhase(after phase: PomodoroPhase) -> PomodoroPhase? {
        var next = phase
        if phase.kind == .focus {
            next.kind = phase.cycle % max(1, phase.longBreakEvery) == 0 ? .longRest : .rest
            return next
        }
        guard phase.cycle < phase.cycles else { return nil }
        next.kind = .focus
        next.cycle = phase.cycle + 1
        return next
    }

    private func begin(_ phase: PomodoroPhase) {
        pomodoro = phase
        if let id = pomodoroTimerID, let i = index(of: id) {
            // Same live activity, next phase: the island never blinks between focus and break.
            timers[i].label = phase.label
            timers[i].state = TimerState(label: phase.label, total: phase.duration,
                                         endDate: Date().addingTimeInterval(phase.duration))
            reprioritize()
            publishAll()
            syncTicker()
            Haptics.tap()
        } else if let id = add(seconds: phase.duration, label: phase.label) {
            pomodoroTimerID = id
        } else {
            pomodoro = nil
        }
    }

    private func stopPomodoro() {
        pomodoroGeneration &+= 1
        pomodoro = nil
        pomodoroTimerID = nil
    }

    // MARK: - Alarms

    /// Sets an alarm for `date`, which has to be still to come, and says so on a card with a
    /// way to take it back. Returns the alarm, or nil for a time that has already gone.
    ///
    /// `followsClock` is an alarm for a time on the clock — the Actions field's, the URL
    /// scheme's — whose hour and minute are kept, so it moves with the clock when the time zone
    /// does (`followTimeZone`). A snooze is nine minutes from now, and does not.
    @discardableResult
    func setAlarm(at date: Date, label: String? = nil, announce: Bool = true, followsClock: Bool = true,
                  now: Date = Date()) -> IslandAlarm? {
        guard date > now else { return nil }
        // A URL can set one before launch has read back the last run's; writing first would
        // write over them.
        loadAlarmsIfNeeded(now: now)
        // The list is brought into this zone first, so the one being added is not the only
        // alarm in it.
        followTimeZone(now: now)
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let alarm = IslandAlarm(label: name.isEmpty ? IslandAlarm.defaultLabel : name, fireDate: date, createdAt: now)
        if followsClock {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            if let hour = parts.hour, let minute = parts.minute { alarmClocks[alarm.id] = AlarmClock(hour: hour, minute: minute) }
        }
        alarms = IslandAlarm.sorted(alarms + [alarm])
        saveAlarms()
        scheduleAlarmCheck(now: now)
        if announce { showAlarmSet(alarm, now: now) }
        return alarm
    }

    /// Takes an alarm away, whether it is still waiting or already ringing.
    func cancelAlarm(id: String) {
        // A URL can cancel one before launch has read back the last run's, see
        // `loadAlarmsIfNeeded`.
        loadAlarmsIfNeeded()
        if entry(id: IslandAlarm.ringingID(id)) != nil { cancel(id: IslandAlarm.ringingID(id)) }
        guard alarms.contains(where: { $0.id == id }) else { return }
        alarms.removeAll { $0.id == id }
        saveAlarms()
        scheduleAlarmCheck()
        // The card that said it was set would otherwise go on saying so.
        if ActivityCenter.shared.alert?.id == Self.alarmSetAlertID { ActivityCenter.shared.dismissAlert() }
    }

    /// Every waiting alarm, gone. A ringing one is a timer by then, and `cancelAll` stops it.
    func cancelAllAlarms() {
        alarmsLoaded = true
        alarms.removeAll()
        alarmClocks.removeAll()
        alarmsZone = TimeZone.current.identifier
        saveAlarms()
        scheduleAlarmCheck()
    }

    /// Drops the alarms in hand without writing anything, as a quit would. Used by the test
    /// suite to stand for a relaunch.
    func forgetAlarmsForTesting() {
        alarmCheck?.invalidate()
        alarmCheck = nil
        alarms = []
        alarmClocks = [:]
        alarmsZone = nil
        alarmsLoaded = false
    }

    /// Nine minutes more of sleep: the alarm that is ringing stops, and comes back.
    func snooze(id: String) {
        guard let ringing = entry(id: id), ringing.state.isAlarm else { return }
        remove(id: id)
        setAlarm(at: Date().addingTimeInterval(Self.snoozeInterval), label: ringing.label, followsClock: false)
    }

    /// Reads back the last run's alarms, unless something already has.
    ///
    /// `notchctl alarm cancel 07:30` with the app not running launches it by URL, and the URL
    /// is handled before launch has got as far as reading the alarms back — or while it waits
    /// for an older copy to quit. A cancel that looked only at what was in hand found an empty
    /// list, cancelled nothing, and the restore that followed brought the alarm back to ring.
    /// So everything that looks the list up to change it reads the disk first, as setting one
    /// always has.
    func loadAlarmsIfNeeded(now: Date = Date()) {
        guard !alarmsLoaded else { return }
        restoreAlarms(now: now)
    }

    /// Reads back the alarms written down by the last run, at launch. Anything already in hand
    /// — a URL that set one before this was called — is kept. One that came due while the app
    /// was not running rings now if it is only just late, and is reported as missed otherwise.
    ///
    /// Written down in one time zone and read back in another — the Mac travelled while the app
    /// was not running — the alarms set for a time on the clock are moved to that time here.
    func restoreAlarms(now: Date = Date()) {
        alarmsLoaded = true
        var saved = IslandAlarm.decode(alarmDefaults.data(forKey: Self.alarmsKey))
        let savedClocks = Self.decodeClocks(alarmDefaults.data(forKey: Self.alarmClocksKey))
        let zone = TimeZone.current
        if let savedZone = alarmDefaults.string(forKey: Self.alarmZoneKey), savedZone != zone.identifier {
            saved = Self.retimed(saved, clocks: savedClocks, now: now, calendar: Self.calendar(in: zone))
        }
        // Anything in hand was set in this run, in the zone it was then.
        if let inHand = alarmsZone, inHand != zone.identifier {
            alarms = Self.retimed(alarms, clocks: alarmClocks, now: now, calendar: Self.calendar(in: zone))
        }
        let known = Set(alarms.map(\.id))
        alarms = IslandAlarm.sorted(alarms + saved.filter { !known.contains($0.id) })
        for (id, clock) in savedClocks where alarmClocks[id] == nil { alarmClocks[id] = clock }
        alarmsZone = zone.identifier
        saveAlarms()
        checkAlarms(now: now)
    }

    /// Rings whatever has come due, reports whatever was missed, and sets the next look.
    func checkAlarms(now: Date = Date()) {
        followTimeZone(now: now)
        let due = IslandAlarm.triage(alarms, now: now, grace: Self.missedGrace)
        if due.pending.count != alarms.count {
            alarms = due.pending
            saveAlarms()
        }
        for alarm in due.ring { ring(alarm, now: now) }
        for alarm in due.missed { reportMissed(alarm, now: now) }
        scheduleAlarmCheck(now: now)
    }

    /// The alarm becomes a timer that has just rung, and goes through the same end as every
    /// timer: the sound, its card taking the island, and a banner when the island cannot be
    /// seen. Its card shows the time it rang for, with Snooze where a timer has Repeat.
    private func ring(_ alarm: IslandAlarm, now: Date) {
        IslandLog.island.notice("alarm ringing, \(Int(now.timeIntervalSince(alarm.fireDate)), privacy: .public)s after its time")
        var state = TimerState(label: alarm.label, total: 1, endDate: alarm.fireDate)
        state.isFinished = true
        state.alarmAt = alarm.fireDate
        let entry = TimerEntry(id: IslandAlarm.ringingID(alarm.id), label: alarm.label, state: state,
                               priority: Self.basePriority, createdAt: now)
        // Never turned away for want of room: a timer that rang and was not dismissed makes way
        // first, and past that the alarm rings over the ceiling. An alarm that does not ring
        // because four pasta timers were running is not an alarm.
        if timers.count >= Self.maxTimers, let stale = timers.first(where: { $0.state.isFinished }) {
            remove(id: stale.id)
        }
        timers.removeAll { $0.id == entry.id }
        timers.append(entry)
        reprioritize()
        ActivityCenter.shared.dismissAlert()
        publishAll()
        finish(entry)
        syncTicker()
    }

    private func showAlarmSet(_ alarm: IslandAlarm, now: Date) {
        var card = CustomActivity(title: "Alarm set for \(IslandAlarm.describe(alarm.fireDate, now: now))")
        card.subtitle = alarm.hasOwnLabel ? alarm.label : nil
        card.symbol = "alarm.fill"
        card.tint = "orange"
        card.body = IslandAlarm.awakeNote
        card.actions = [CustomAction(title: "Cancel", command: .cancelAlarm(id: alarm.id))]
        ActivityCenter.shared.showAlert(IslandActivity(id: Self.alarmSetAlertID, kind: .custom, content: .custom(card),
                                                       priority: 80, presentation: .expanded), duration: 5)
    }

    /// The card, and a banner as well whenever the card cannot be seen, see `missedNeedsBanner`
    /// — or, where that banner would have to ask for Notifications at the lock screen, the
    /// card again once somebody is at the Mac (`missedWaitsForUnlock`).
    private func reportMissed(_ alarm: IslandAlarm, now: Date) {
        IslandLog.island.notice("alarm missed by \(Int(now.timeIntervalSince(alarm.fireDate)), privacy: .public)s")
        // Against the moment it is reported, so one missed days ago says which day.
        let title = "Missed alarm, \(IslandAlarm.describe(alarm.fireDate, now: now))"
        var card = CustomActivity(title: title)
        card.subtitle = alarm.hasOwnLabel ? alarm.label : nil
        card.symbol = "alarm"
        card.tint = "orange"
        card.body = Self.missedNote
        ActivityCenter.shared.showAlert(IslandActivity(id: Self.alarmMissedAlertID, kind: .custom, content: .custom(card),
                                                       priority: 85, presentation: .expanded), duration: 8)
        let locked = ScreenLockMonitor.screenIsLockedOrAsleep
        let suppressed = ActivityCenter.shared.isSuppressed
        guard locked || suppressed else { return }
        let body = alarm.hasOwnLabel ? alarm.label + ". " + Self.missedNote : Self.missedNote
        notificationsAllowed { [weak self] authorized in
            guard let self else { return }
            if Self.missedNeedsBanner(locked: locked, suppressed: suppressed, authorized: authorized) {
                self.postBanner(title: title, body: body, id: "alarm-missed.\(alarm.id)")
            } else if Self.missedWaitsForUnlock(locked: locked, authorized: authorized) {
                IslandLog.island.notice("missed alarm kept for the unlock: Notifications are not allowed yet")
                self.reportAtUnlock(alarm)
            }
        }
    }

    static let missedNote = "The Mac was asleep, or Notch Island was not running, when it was due."

    /// Whether a missed alarm needs a banner as well as its card. Pure, so it is tested.
    ///
    /// A missed alarm is found at wake, and a Mac wakes to its lock screen: the eight-second
    /// card came and went behind it, and the one thing that said the alarm had been missed was
    /// seen by nobody. A banner waits in Notification Centre for whoever unlocks. It is the
    /// rule a ringing timer's banner follows — only when the island cannot be seen: locked,
    /// asleep, hidden, or under an app full screen — and not otherwise, where it would only
    /// say what the card is saying.
    ///
    /// At the lock screen, only where Notifications are allowed already (`authorized`). The
    /// first banner asks for them, and that question was put at the lock screen, to nobody or
    /// to whoever passed; refused, no banner is posted anyway. Such an alarm waits for the
    /// unlock instead (`missedWaitsForUnlock`). With the Mac unlocked and the island hidden
    /// somebody is there to answer, and the banner asks as any first banner does.
    static func missedNeedsBanner(locked: Bool, suppressed: Bool, authorized: Bool) -> Bool {
        if locked { return authorized }
        return suppressed
    }

    /// Whether a missed alarm is reported again at the unlock rather than now: nobody can see
    /// its card, and a banner could not be posted without asking first, or at all. At the
    /// unlock its card comes back, where somebody can see it, and the banner follows if the
    /// island is hidden even then.
    static func missedWaitsForUnlock(locked: Bool, authorized: Bool) -> Bool {
        locked && !authorized
    }

    /// Keeps `alarm` for the unlock, see `missedWaitsForUnlock`. The display waking with no
    /// lock to get past counts as well: a display that was only asleep has no unlock to wait
    /// for.
    private func reportAtUnlock(_ alarm: IslandAlarm) {
        missedAtUnlock.removeAll { $0.id == alarm.id }
        missedAtUnlock.append(alarm)
        guard unlockObservers.isEmpty else { return }
        let distributed: NotificationCenter = DistributedNotificationCenter.default()
        let unlock = distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                             object: nil, queue: .main) { [weak self] _ in
            self?.somebodyIsBack(unlocked: true)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.somebodyIsBack(unlocked: false)
        }
        unlockObservers = [(distributed, unlock), (workspace, wake)]
    }

    /// The screen was unlocked, or the display woke. Missed alarms kept for this are reported
    /// now — a moment after, so the unlock's own tick on the island is not cut short by them.
    private func somebodyIsBack(unlocked: Bool) {
        guard unlocked || !ScreenLockMonitor.screenIsLockedOrAsleep else { return }
        for (center, token) in unlockObservers { center.removeObserver(token) }
        unlockObservers.removeAll()
        let waiting = missedAtUnlock
        missedAtUnlock.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.afterUnlock) { [weak self] in
            for alarm in waiting { self?.reportMissed(alarm, now: Date()) }
        }
    }

    /// Longer than the unlock's own alert at the length it ships with (`ScreenLockMonitor`),
    /// which a missed alarm's card would otherwise replace.
    static let afterUnlock: TimeInterval = 1.5

    /// Whether Notifications are allowed already, so that a banner goes without a question.
    /// The notification centre answers on a queue of its own; the answer comes on the main
    /// queue. Unbundled — `swift test` — nothing is asked and nothing answers, since the
    /// centre traps there and no banner is ever posted (`postBanner`).
    private func notificationsAllowed(_ answer: @escaping (Bool) -> Void) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            let allowed = status == .authorized || status == .provisional
            DispatchQueue.main.async { answer(allowed) }
        }
    }

    private func saveAlarms() {
        guard let data = IslandAlarm.encode(alarms) else { return }
        alarmDefaults.set(data, forKey: Self.alarmsKey)
        // Only the clocks of alarms still waiting: one that rang or was cancelled takes its own.
        let waiting = Set(alarms.map(\.id))
        alarmClocks = alarmClocks.filter { waiting.contains($0.key) }
        if let clocks = try? JSONEncoder().encode(alarmClocks) { alarmDefaults.set(clocks, forKey: Self.alarmClocksKey) }
        alarmDefaults.set(alarmsZone ?? TimeZone.current.identifier, forKey: Self.alarmZoneKey)
    }

    /// The clocks as they were written down; nothing readable is none, and then every alarm
    /// keeps the moment it has.
    static func decodeClocks(_ data: Data?) -> [String: AlarmClock] {
        guard let data, let clocks = try? JSONDecoder().decode([String: AlarmClock].self, from: data) else { return [:] }
        return clocks
    }

    /// The Mac's calendar, in `zone`.
    private static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return calendar
    }

    // MARK: - Alarms across a change of time zone

    /// The alarms once the clock is in the zone `calendar` is: each one set for a time on the
    /// clock and still to come is the next time the clock reads that time now. One whose time
    /// has already come is left as it is, for `IslandAlarm.triage` to ring or report — as is a
    /// snooze, which has no time on the clock (`AlarmClock`).
    ///
    /// An alarm kept its moment, and `notchctl alarm 07:30` in London rang at half past two in
    /// the morning in New York. Pure, so it is tested.
    static func retimed(_ alarms: [IslandAlarm], clocks: [String: AlarmClock], now: Date,
                        calendar: Calendar) -> [IslandAlarm] {
        IslandAlarm.sorted(alarms.map { (alarm: IslandAlarm) -> IslandAlarm in
            guard alarm.fireDate > now, let clock = clocks[alarm.id],
                  let fire = IslandAlarm.nextFire(hour: clock.hour, minute: clock.minute, after: now, calendar: calendar)
            else { return alarm }
            var moved = alarm
            moved.fireDate = fire
            return moved
        })
    }

    /// Brings the alarms into `zone` when it is not the one they were worked out in, and writes
    /// them down there. Returns whether anything moved. Heard from `NSSystemTimeZoneDidChange`
    /// through `checkAlarms`, and asked before anything is added.
    @discardableResult
    func followTimeZone(_ zone: TimeZone = .current, now: Date = Date()) -> Bool {
        guard let from = alarmsZone, from != zone.identifier else {
            alarmsZone = zone.identifier
            return false
        }
        let moved = Self.retimed(alarms, clocks: alarmClocks, now: now, calendar: Self.calendar(in: zone))
        alarmsZone = zone.identifier
        guard moved != alarms else {
            saveAlarms()
            return false
        }
        IslandLog.island.notice("alarms moved to the clock in \(zone.identifier, privacy: .public)")
        alarms = moved
        saveAlarms()
        scheduleAlarmCheck(now: now)
        return true
    }

    /// One look at the clock, set for the soonest alarm or the ceiling, whichever is first —
    /// and none at all while there is no alarm. Added in the common modes, so a menu held open
    /// at seven in the morning does not hold the alarm back.
    private func scheduleAlarmCheck(now: Date = Date()) {
        alarmCheck?.invalidate()
        alarmCheck = nil
        guard let next = alarms.first?.fireDate else { return }
        watchTheClock()
        let delay = min(max(0.25, next.timeIntervalSince(now)), Self.alarmCheckCeiling)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.checkAlarms() }
        timer.tolerance = delay > 5 ? 1 : 0.1
        RunLoop.main.add(timer, forMode: .common)
        alarmCheck = timer
    }

    /// A timer's clock stops while the Mac sleeps, and knows nothing of the wall clock being
    /// set. Both are heard here instead, and each is a look straight away.
    private func watchTheClock() {
        guard alarmObservers.isEmpty else { return }
        alarmObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.checkAlarms() })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            alarmObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] note in
                // The zone the process has in hand is cached until it is told to look again.
                if note.name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
                self?.checkAlarms()
            })
        }
    }

    // MARK: - Ticking

    /// One shared look for every timer, set for the next moment one of them has something to
    /// happen, and none at all while they are all paused or done (`nextTick`).
    ///
    /// It was a 1 Hz ticker with 0.15 s of tolerance, which woke every second a timer ran —
    /// a twenty-five-minute Pomodoro phase is fifteen hundred wakeups to notice one moment —
    /// and rang up to 1.15 s after the countdown reached zero. The digits never came from it:
    /// every view that shows a countdown draws it from a `TimelineView` of its own, which runs
    /// only while it is on screen. So the look is a one-shot at the soonest end, the way the
    /// alarm check is, and it rings on time. Added in the common modes, like the alarm check:
    /// a timer in the default mode alone does not fire while a menu is held open or a slider
    /// dragged, so a countdown that ran out then rang only when the menu closed.
    private func syncTicker(now: Date = Date()) {
        ticker?.invalidate()
        ticker = nil
        guard let next = Self.nextTick(for: timers, now: now) else {
            stopWatchingTheClockForTimers()
            return
        }
        watchTheClockForTimers()
        let t = Timer(timeInterval: max(0, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in self?.tick() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// When the ticker next has something to do: the soonest a running timer reaches zero, or,
    /// if sooner, the moment a running timer's time left falls below a paused one's, which
    /// changes which of them has the island (`reprioritize`). The overtaking is looked at a
    /// hair after the moment, so the look finds the order already changed. Nil with nothing
    /// running, which is no look at all. Pure, so it is tested.
    static func nextTick(for timers: [TimerEntry], now: Date) -> Date? {
        let running = timers.filter { !$0.state.isFinished && !$0.state.isPaused }
        guard var next = running.map(\.state.endDate).min() else { return nil }
        let paused = timers.compactMap { $0.state.isFinished ? nil : $0.state.pausedRemaining }
        for timer in running {
            for waiting in paused {
                let overtakes = timer.state.endDate.addingTimeInterval(-waiting + overtakeMargin)
                if overtakes > now, overtakes < next { next = overtakes }
            }
        }
        return next
    }

    static let overtakeMargin: TimeInterval = 0.05

    /// A timer's clock stops while the Mac sleeps, and knows nothing of the wall clock being
    /// set, and a one-shot set for a countdown's end would ring as late as the sleep was long.
    /// Both are heard here instead, for as long as a timer runs, and each is a look straight
    /// away — as the alarm check does for alarms (`watchTheClock`).
    private func watchTheClockForTimers() {
        guard tickerObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        tickerObservers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }))
        let local = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            tickerObservers.append((local, local.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.tick()
            }))
        }
    }

    private func stopWatchingTheClockForTimers() {
        for (center, token) in tickerObservers { center.removeObserver(token) }
        tickerObservers.removeAll()
    }

    private func tick() {
        let now = Date()
        var justFinished: [TimerEntry] = []
        for i in timers.indices where !timers[i].state.isFinished && !timers[i].state.isPaused {
            guard timers[i].state.remaining(at: now) <= 0 else { continue }
            timers[i].state.isFinished = true
            justFinished.append(timers[i])
        }
        // A paused timer can be overtaken by a running one, so the island order is worth
        // re-checking even when nothing has finished.
        let reordered = reprioritize()
        if reordered || !justFinished.isEmpty { publishAll() }
        for entry in justFinished { finish(entry) }
        // The look is spent: the next one, if anything is still running.
        syncTicker()
    }

    private func finish(_ entry: TimerEntry) {
        // A sleep timer's job is the silence at the end of it, so it does not ring: waking
        // somebody to tell them the music has stopped is the opposite of what they asked for.
        if entry.whenDone == .pausePlayback {
            NowPlayingService.shared.pauseIfPlaying()
            remove(id: entry.id)
            return
        }
        if Preferences.shared.timerSoundEnabled {
            NSSound(named: "Glass")?.play()
        }
        // The finished timer's own expanded view is the alert, the way the Clock app's Live
        // Activity takes over the island when it goes off.
        ActivityCenter.shared.forceExpanded(id: entry.id, for: 8)
        // The banner is for when that cannot be seen: the island hidden, an app full screen
        // over it, or the screen locked or asleep with nobody at it — which is what Privacy
        // says it is for. Posted every time, it doubled every timer with a banner, and asked
        // for Notifications the first time any timer rang.
        if ActivityCenter.shared.isSuppressed || ScreenLockMonitor.screenIsLockedOrAsleep { notify(entry) }

        if entry.id == pomodoroTimerID, let phase = pomodoro, let next = Self.nextPhase(after: phase) {
            // Let the finished phase sit on screen for a beat, then roll into the next one.
            let generation = pomodoroGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.pomodoroGeneration == generation, self.pomodoroTimerID == entry.id else { return }
                self.begin(next)
            }
            return
        }
        if entry.id == pomodoroTimerID { stopPomodoro() }

        // Auto-clear a finished timer after a minute if nobody stops it. Ids can be reused, so
        // only clear the very timer that finished.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, let current = self.entry(id: entry.id),
                  current.createdAt == entry.createdAt, current.state.isFinished else { return }
            self.cancel(id: entry.id)
        }
    }

    /// Banner for a timer that went off while the island was hidden or another app was full
    /// screen.
    private func notify(_ entry: TimerEntry) {
        // An alarm's banner says the time it rang for, which is the thing a banner read later
        // most needs to say.
        let title = entry.state.alarmAt.map { "Alarm, " + IslandAlarm.describe($0) } ?? "Timer"
        postBanner(title: title, body: entry.label, id: entry.id)
    }

    /// Posts a banner through Notification Centre, asking for Notifications the first time.
    /// Only a real .app bundle may talk to the notification centre — `swift test` runs
    /// unbundled, where touching it would trap — so this is a no-op there.
    private func postBanner(title: String, body: String, id: String) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let deliver: () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: "notchisland.timer.\(id).\(Date().timeIntervalSince1970)",
                                                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    IslandLog.island.error("timer notification failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if askedForNotifications {
            deliver()
            return
        }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                IslandLog.island.error("notification authorisation failed: \(error.localizedDescription, privacy: .public)")
            }
            guard granted else { return }
            DispatchQueue.main.async(execute: deliver)
        }
    }

    // MARK: - Live activities

    private func publish(_ entry: TimerEntry) {
        ActivityCenter.shared.upsert(IslandActivity(id: entry.id, kind: .timer,
                                                    content: .timer(entry.state), priority: entry.priority))
    }

    private func publishAll() {
        for entry in timers { publish(entry) }
    }
}
