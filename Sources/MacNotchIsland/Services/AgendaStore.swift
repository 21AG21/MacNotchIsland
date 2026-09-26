import AppKit
import Combine
import EventKit
import Foundation

/// Today, for the Home panel: the calendar events still ahead in the next 24 hours (and never
/// short of the end of today, see `fetchEnd`) and the reminders due by the end of the day.
/// Nothing is asked of EventKit until a view that shows the agenda appears; access is requested
/// once, from a view somebody pinned open (`Hold`), and the store keeps itself fresh with the
/// system's change notification plus a slow timer while such a view is on screen.
///
/// None of that asking happens on the main thread. A calendar in an Exchange or CalDAV
/// account is not a file on this Mac: reading it is a round trip to somebody's mail server,
/// and so is ticking a reminder off, and both used to happen on the thread that draws the
/// panel — a minute's poll and a button press that could each stop the notch dead for as long
/// as the far end took to answer. Everything EventKit is asked now happens on `queue`;
/// everything published from it comes back to the main queue to be shown, without exception.
final class AgendaStore: ObservableObject {
    static let shared = AgendaStore()

    struct Event: Identifiable, Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var location: String?
        var joinURL: URL?
        /// Calendar colour as a hex string, for `Color.named`.
        var tint: String
    }

    struct Reminder: Identifiable, Equatable {
        var id: String
        var title: String
        var due: Date?
        var isCompleted: Bool
        /// 0 (none) … 9; EventKit's 1 is the highest.
        var priority: Int
        var tint: String
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var reminders: [Reminder] = []
    @Published private(set) var eventsAccess = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var remindersAccess = EKEventStore.authorizationStatus(for: .reminder)

    private let store = EKEventStore()
    /// Where the waiting on EventKit happens. Serial, so a tick is written after any reading
    /// already in the air and before the one that comes after it.
    private let queue = DispatchQueue(label: "com.macnotchisland.agenda", qos: .utility)
    /// One pass at a time, for the same reason the radios keep to one reader: two fetches in
    /// flight together are two round trips for one answer, and the slower of them lands last
    /// carrying the older news.
    private var pass = RadioPass()
    /// The reading now in flight: which one it is, and the moment it was asked for.
    ///
    /// `fetchReminders` takes a completion and promises nothing about calling it — access can
    /// be taken away mid-flight, and an account can simply never come back — so a reading that
    /// has gone quiet is given up on rather than waited on for the rest of the session. The
    /// number is what tells an answer arriving after that it is speaking to nobody.
    ///
    /// Main queue, like everything else here that decides what is shown.
    private var reading = 0
    private var asked: Date?
    /// What the store last said about the reminders, before anything the user has since asked
    /// for is laid over the top. Main queue, like everything else that decides what is shown.
    private var fetched: [Reminder] = []
    /// Ticks made here that Reminders itself has not confirmed yet, by reminder.
    private var ticked: [String: Tick] = [:]
    private var viewers = 0
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var requested = false

    private init() {}

    // MARK: - The gallery

    /// Puts a day in the store for the rendered gallery, which runs on a machine with no
    /// calendar to read and would otherwise only ever show the empty state. Does nothing
    /// outside the gallery, so the shipping app can never be handed invented events.
    func seedForGallery(events: [Event], reminders: [Reminder]) {
        guard RenderMode.isGallery else { return }
        self.events = events
        self.fetched = reminders
        self.reminders = reminders
        eventsAccess = .fullAccess
        remindersAccess = .fullAccess
    }

    // MARK: - Lifetime

    /// How a view that shows the day holds the agenda.
    ///
    /// Reading and asking are two things. The first viewer used to be what asked macOS for
    /// Reminders, so a peek — the Home grid opens under a pointer resting on the bare notch —
    /// was kept off the agenda altogether while a question was still to be put, and after the
    /// tour that is every new Mac: the tour answers Calendars, and Reminders waits for the
    /// agenda's first viewer. The peek's Today tile said "Nothing today" over a day of
    /// meetings until a panel had been pinned open once. A peek reads now, whatever it may
    /// not ask for; only a panel somebody opened asks.
    enum Hold: Equatable {
        /// Not a viewer.
        case off
        /// A viewer that reads what has already been granted and asks for nothing.
        case reading
        /// A viewer that may put the questions never answered, once a session.
        case asking
    }

    /// What moving one view's hold from `old` to `new` asks of the store.
    enum HoldChange: Equatable {
        case nothing
        case appear(mayAsk: Bool)
        case ask
        case disappear
    }

    /// Pure, so the steps are tested. A viewer that stops being allowed to ask stays a viewer:
    /// a question already on screen is not taken back, and the day it reads is as good as ever.
    static func change(from old: Hold, to new: Hold) -> HoldChange {
        guard old != new else { return .nothing }
        if old == .off { return .appear(mayAsk: new == .asking) }
        if new == .off { return .disappear }
        return new == .asking ? .ask : .nothing
    }

    /// Moves one view's hold on the agenda from `old` to `new`. Main thread, from the view.
    func move(from old: Hold, to new: Hold) {
        switch Self.change(from: old, to: new) {
        case .nothing: break
        case .appear(let mayAsk): viewerAppeared(mayAsk: mayAsk)
        case .ask: requestAccessIfNeeded()
        case .disappear: viewerDisappeared()
        }
    }

    /// A view that shows the agenda appeared. One that `mayAsk` puts the questions never
    /// answered, the first time any viewer may; one that may not reads only what has already
    /// been granted.
    func viewerAppeared(mayAsk: Bool) {
        viewers += 1
        if mayAsk { requestAccessIfNeeded() }
        guard viewers == 1 else { return }
        // Today ends at midnight by `Calendar.current`, which reads the zone the process has in
        // hand, and the process holds on to the zone it first read until it is told to look
        // again. What tells it listens from here on (`LiveDateFormatter.changesHeard`), so a
        // Mac that changes zone has its day end at the new midnight by the next minute's poll.
        _ = LiveDateFormatter.changesHeard()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Puts the questions never answered, once a session. Read live rather than from the
    /// published pair, which are only brought up to date by a reading — and the calendar's is
    /// usually answered by `CalendarMonitor`, while nothing here was looking. Main thread,
    /// and only for a viewer somebody opened (`Hold.asking`).
    private func requestAccessIfNeeded() {
        // The gallery is handed its day, and a question from it would stand over every
        // picture taken after it: the seeded pair kept it from asking when the pair was read.
        guard !RenderMode.isGallery else { return }
        let events = EKEventStore.authorizationStatus(for: .event)
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        guard Self.wouldAsk(requested: requested, events: events, reminders: reminders) else { return }
        requested = true
        if events == .notDetermined {
            store.requestFullAccessToEvents { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.eventsAccess = EKEventStore.authorizationStatus(for: .event)
                    self?.refresh()
                }
            }
        }
        if reminders == .notDetermined {
            store.requestFullAccessToReminders { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
                    self?.refresh()
                }
            }
        }
    }

    /// Pure: `requestAccessIfNeeded` asks once a session, and only for a permission not yet
    /// answered either way. No view reads this to decide whether to hold the agenda any more
    /// — a peek holds it to read (`Hold.reading`) — so nothing reads the two permissions on
    /// every pass of a view's body either.
    static func wouldAsk(requested: Bool, events: EKAuthorizationStatus, reminders: EKAuthorizationStatus) -> Bool {
        !requested && (events == .notDetermined || reminders == .notDetermined)
    }

    var canReadEvents: Bool { eventsAccess == .fullAccess }
    var canReadReminders: Bool { remindersAccess == .fullAccess }

    /// Reads both permissions again. They are granted in System Settings, which tells nobody,
    /// and read once they left Today saying "Calendar access is off" until the app was
    /// relaunched, however long ago the switch had been thrown. Every reading of the day looks
    /// first — the minute's poll and the section appearing are both one.
    private func rereadAccess() {
        let events = EKEventStore.authorizationStatus(for: .event)
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        let granted = Self.newlyGranted(was: eventsAccess, now: events)
            || Self.newlyGranted(was: remindersAccess, now: reminders)
        if eventsAccess != events { eventsAccess = events }
        if remindersAccess != reminders { remindersAccess = reminders }
        // A store made before the grant can go on seeing no calendars at all; starting it
        // afresh is what lets it see them. On the queue, ahead of the reading about to be
        // handed to it there.
        if granted { queue.async { [weak self] in self?.store.reset() } }
    }

    /// Whether a permission has just turned into one the store can read with.
    static func newlyGranted(was old: EKAuthorizationStatus, now new: EKAuthorizationStatus) -> Bool {
        new == .fullAccess && old != .fullAccess
    }

    // MARK: - Reading

    /// Asks for the day. Called on the main thread — from the timer, from the system's change
    /// notification, and from the button that has just ticked something off — and returns from
    /// it straight away, having handed the asking to the queue.
    func refresh() {
        // The gallery is handed its day rather than reading one, and this machine has no
        // calendar: refreshing here would only take the seeded day away again.
        guard !RenderMode.isGallery else { return }
        rereadAccess()
        giveUpOnAStuckReading()
        guard pass.start() else { return }
        let now = Date()
        reading += 1
        asked = now
        let answering = reading
        // Both answers are read where they are shown, before anything leaves the main queue:
        // they are published properties, and a published property is main-thread-only.
        let wantsEvents = canReadEvents
        let wantsReminders = canReadReminders
        queue.async { [weak self] in
            guard let self else { return }
            let day = wantsEvents ? Self.dayEvents(in: self.store, at: now) : []
            guard wantsReminders else {
                self.publish(events: day, reminders: [], answering: answering)
                return
            }
            let predicate = self.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: Self.endOfDay(for: now),
                                                                       calendars: nil)
            // Answers on a queue of EventKit's own choosing, which is why the pass is not
            // finished until this half is in too.
            self.store.fetchReminders(matching: predicate) { [weak self] found in
                self?.publish(events: day, reminders: Self.dueReminders(from: found ?? []), answering: answering)
            }
        }
    }

    /// The midnight that ends the day `now` is in: the start of the next day by the calendar,
    /// not twenty-four hours after this one's. On the day the clocks change those are an hour
    /// apart — the autumn day is twenty-five hours long, so an 11:30 PM meeting read as
    /// tomorrow's and the reminders due in the last hour were left out of today's; the spring
    /// one is twenty-three, and the first hour of tomorrow was counted as today's.
    ///
    /// Pure, so the two awkward days can be tested with a calendar of their own.
    static func endOfDay(for now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
    }

    /// How far ahead the events are read: the next twenty-four hours, or to the end of today
    /// when that is further. On the day the clocks go back the day is twenty-five hours long,
    /// and between midnight and one in the morning twenty-four hours stopped short of it: the
    /// last hour of the day was never read, and a meeting in it was missing from Today until
    /// one o'clock came. Pure, so the long day is tested.
    static func fetchEnd(for now: Date, calendar: Calendar = .current) -> Date {
        max(now.addingTimeInterval(24 * 3600), endOfDay(for: now, calendar: calendar))
    }

    /// Where every reading lands, and the only place any of this is written: the main queue.
    private func publish(events: [Event], reminders: [Reminder], answering: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // An answer to a reading that was given up on is speaking to nobody: it must not
            // put an old day on screen, and it must not hand back a gate it no longer holds.
            guard Self.answers(answering, current: self.reading) else { return }
            self.asked = nil
            if self.events != events { self.events = events }
            self.fetched = reminders
            self.ticked = Self.settling(self.ticked, against: reminders)
            self.show()
            // Somebody ticked a reminder off while this pass was in the air. The answer that
            // matters is the next one, not the one the minute's poll gets round to.
            if self.pass.finish() { self.refresh() }
        }
    }

    /// The list as the panel should read it: what the store last said, with any tick the user
    /// has made and Reminders has not caught up with laid over the top.
    private func show() {
        let shown = Self.showing(fetched, ticked: ticked)
        if reminders != shown { reminders = shown }
    }

    // MARK: - A reading that never answers

    /// How long a reading may go unanswered before the store stops waiting on it. Longer than
    /// an honest round trip to somebody's mail server, and shorter than the minute's poll, so
    /// the first poll to come round after a fetch has gone quiet is the one that frees it.
    static let readingDeadline: TimeInterval = 30

    /// Whether a reading asked for at `started` has had long enough. Waiting on one for ever
    /// was how the section came to sit on yesterday for the rest of a session: the pass was
    /// never finished, so the poll, the change notification and the reading behind a tick all
    /// stood down behind it, and nothing was ever going to come along and let them through.
    static func abandons(startedAt started: Date, at now: Date = Date()) -> Bool {
        now.timeIntervalSince(started) >= readingDeadline
    }

    /// Whether an answer belongs to the reading still in flight. One that was given up on can
    /// still come back — nothing here can cancel an EventKit fetch, there being no handle to
    /// cancel — and by then the day it is carrying is old news and the gate it would hand back
    /// belongs to somebody else.
    static func answers(_ reading: Int, current: Int) -> Bool { reading == current }

    /// Stops waiting on a reading that has gone quiet, so the ask about to be made can go.
    /// Main thread, from the top of `refresh`, which is the one thing that comes back to look.
    private func giveUpOnAStuckReading() {
        guard pass.isRunning, let started = asked, Self.abandons(startedAt: started) else { return }
        IslandLog.store.error("a reading of the day went unanswered; giving up on it")
        reading += 1
        asked = nil
        // Whatever was asked for while it ran is served by the ask this is clearing the way for.
        _ = pass.finish()
    }

    /// The next day's events, turned into something the panel can hold before they go
    /// anywhere near the main thread. An `EKEvent` belongs to the thread that fetched it, so
    /// the mapping happens here rather than on the other side of the hand-off.
    private static func dayEvents(in store: EKEventStore, at now: Date) -> [Event] {
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-5 * 60), end: fetchEnd(for: now), calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled && $0.endDate > now }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return !a.isAllDay }
                return a.startDate < b.startDate
            }
            .prefix(12)
            .map(Self.event(from:))
    }

    /// The same for what is due: soonest first, and the keenest of the ones with no time on
    /// them at all.
    private static func dueReminders(from found: [EKReminder]) -> [Reminder] {
        return found
            .sorted { a, b in
                let da = dueDate(a.dueDateComponents) ?? .distantFuture
                let db = dueDate(b.dueDateComponents) ?? .distantFuture
                if da != db { return da < db }
                return a.priority < b.priority
            }
            .prefix(12)
            .map(Self.reminder(from:))
    }

    // MARK: - Ticking one off

    /// Ticks a reminder off (or back on) in Reminders itself.
    ///
    /// The tick lands the instant it is pressed and the writing happens behind it: `save`
    /// commits through to whatever account the list lives in, which is not something a button
    /// may wait for with the pointer still down. If the write is refused the reminder comes
    /// straight back, because a row that returns a second later with nothing said reads as the
    /// app being broken rather than as the answer being no.
    ///
    /// Main thread, from the row that was pressed.
    func setCompleted(_ completed: Bool, reminderID: String) {
        expect(completed, for: reminderID)
        queue.async { [weak self] in
            guard let self else { return }
            var saved = false
            if let item = self.store.calendarItem(withIdentifier: reminderID) as? EKReminder {
                item.isCompleted = completed
                do {
                    try self.store.save(item, commit: true)
                    saved = true
                } catch {
                    IslandLog.store.error("reminder not ticked off: \(error.localizedDescription, privacy: .public)")
                }
            }
            DispatchQueue.main.async {
                if !saved { self.forget(reminderID) }
                self.refresh()
            }
        }
    }

    /// What the user has just asked for, shown at once and held until Reminders agrees.
    private func expect(_ completed: Bool, for id: String) {
        ticked[id] = Tick(completed: completed, until: Date().addingTimeInterval(Self.tickSettle))
        show()
    }

    /// The write was refused, so what is shown goes back to what the store last said.
    private func forget(_ id: String) {
        guard ticked.removeValue(forKey: id) != nil else { return }
        show()
    }

    // MARK: - What the user has asked for and the store has not caught up with

    /// A tick made here, and the moment the list stops holding it against what the store says.
    struct Tick: Equatable {
        var completed: Bool
        var until: Date
    }

    /// How long a tick is believed over the store. Longer than the rail gives its switches: a
    /// reminder in an account on somebody's server is saved over the wire, and the reading
    /// that confirms it comes back over the wire too.
    static let tickSettle: TimeInterval = 5

    /// Whether what the store now says about a reminder is worth showing, or is older than the
    /// user's own last word on it. A reading that agrees settles the wait early; one that is
    /// still arguing when the window is up is believed, because by then the answer is no.
    static func accepts(_ completed: Bool, waitingFor waiting: Tick?, at now: Date = Date()) -> Bool {
        guard let waiting else { return true }
        return now >= waiting.until || waiting.completed == completed
    }

    /// The list to draw while a tick is in the air. A reminder ticked off leaves the list
    /// altogether — the fetch asks only for what is outstanding — so this is what stands
    /// between the press and the answer, and what keeps a row from flicking back into place
    /// because a reading that left before the press landed after it.
    static func showing(_ fetched: [Reminder], ticked: [String: Tick], at now: Date = Date()) -> [Reminder] {
        guard !ticked.isEmpty else { return fetched }
        return fetched.map { reminder in
            guard let tick = ticked[reminder.id],
                  !accepts(reminder.isCompleted, waitingFor: tick, at: now) else { return reminder }
            var held = reminder
            held.isCompleted = tick.completed
            return held
        }
    }

    /// Which ticks are still worth holding once a reading has come back. One the store agrees
    /// with is done with, and so is one that has waited out its window and lost the argument.
    /// A reminder gone from the list is the store agreeing that it is finished, that being the
    /// only way a completed one can be reported by a fetch that never asks for them.
    static func settling(_ ticked: [String: Tick], against fetched: [Reminder], at now: Date = Date()) -> [String: Tick] {
        guard !ticked.isEmpty else { return ticked }
        var kept: [String: Tick] = [:]
        for (id, tick) in ticked where now < tick.until {
            let completed = fetched.first(where: { $0.id == id })?.isCompleted ?? true
            if completed != tick.completed { kept[id] = tick }
        }
        return kept
    }

    // MARK: - Mapping

    private static func event(from e: EKEvent) -> Event {
        Event(id: rowID(e.eventIdentifier, start: e.startDate), title: e.title ?? "Event", start: e.startDate, end: e.endDate,
              isAllDay: e.isAllDay, location: e.location?.trimmingCharacters(in: .whitespacesAndNewlines),
              joinURL: CalendarMonitor.meetingLink(in: e), tint: tint(of: e.calendar))
    }

    /// A Today row's id: the event's, and when this occurrence of it starts. Every occurrence
    /// of a repeating event carries the same `eventIdentifier`, so a stand-up at nine and again
    /// at five were two rows with one id, and the list drew one of them twice or dropped one.
    /// Pure, so it is tested.
    static func rowID(_ identifier: String?, start: Date) -> String {
        (identifier ?? UUID().uuidString) + "@" + String(format: "%.0f", start.timeIntervalSince1970.rounded(.down))
    }

    /// When a reminder is due. `DateComponents.date` is nil for components that carry no
    /// calendar, and a reminder whose due date came without one sorted after every other and
    /// said nothing about when it was due; the Mac's calendar reads them instead. Pure, so it is
    /// tested.
    static func dueDate(_ components: DateComponents?, calendar: Calendar = .current) -> Date? {
        guard let components else { return nil }
        return components.date ?? calendar.date(from: components)
    }

    private static func reminder(from r: EKReminder) -> Reminder {
        Reminder(id: r.calendarItemIdentifier, title: r.title ?? "Reminder", due: dueDate(r.dueDateComponents),
                 isCompleted: r.isCompleted, priority: r.priority, tint: tint(of: r.calendar))
    }

    private static func tint(of calendar: EKCalendar?) -> String {
        guard let cg = calendar?.cgColor, let ns = NSColor(cgColor: cg) else { return "blue" }
        return ns.hexString
    }

    /// "9:30 AM", "All day", "Now" — how an event's start reads in a short list.
    static func timeLabel(for event: Event, at now: Date = Date()) -> String {
        if event.isAllDay { return "All day" }
        if event.start <= now && event.end > now { return "Now" }
        return Self.timeFormatter.string(from: event.start)
    }

    static func dueLabel(for reminder: Reminder, at now: Date = Date()) -> String? {
        guard let due = reminder.due else { return nil }
        if Calendar.current.isDate(due, inSameDayAs: now) {
            // A reminder due "today" with no time carries midnight; say so plainly.
            let components = Calendar.current.dateComponents([.hour, .minute], from: due)
            if components.hour == 0 && components.minute == 0 { return "Today" }
            return timeFormatter.string(from: due)
        }
        return due < now ? "Overdue" : Self.dayFormatter.string(from: due)
    }

    // Both made again when the 24-hour switch, the region or the zone changes: kept as they
    // were made, they wrote the day in the old ones until a relaunch (`LiveDateFormatter`).
    private static let timeFormatter = LiveDateFormatter { f in
        f.timeStyle = .short
        f.dateStyle = .none
    }

    private static let dayFormatter = LiveDateFormatter { f in
        f.dateFormat = "EEE"
    }

    // MARK: - Counting down to an event

    /// How often a countdown to an event is looked at again.
    static let countdownStep: TimeInterval = 30

    /// Where a countdown's timeline starts: a whole number of steps before the event starts,
    /// already past, and a hair after that moment.
    ///
    /// A countdown's words change at the event's own minutes ("in 2 min" becomes "in 1 min" a
    /// minute before it starts, "Now" at the start), and its timeline ticked every half minute
    /// from whenever the view appeared: up to thirty seconds after a meeting had begun its row
    /// still said "in 1 min". Counted from the start instead, every look lands on one of those
    /// moments. A hair after, so the look finds the words already changed rather than on the
    /// edge of changing; and in the past, so the timeline has a first look to give now rather
    /// than one it is waiting for. Pure, so it is tested.
    static func countdownPhase(for start: Date, now: Date, step: TimeInterval = AgendaStore.countdownStep) -> Date {
        let steps = (start.timeIntervalSince(now) / step).rounded(.down) + 2
        return start.addingTimeInterval(-steps * step + countdownHair)
    }

    /// The hair: late enough to be past the moment whatever the arithmetic of a date rounds to,
    /// and far too soon after it for anybody to see.
    static let countdownHair: TimeInterval = 0.05
}
