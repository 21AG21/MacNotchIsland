import AppKit
import Combine
import EventKit
import Foundation

/// Today, for the Home panel: the calendar events still ahead in the next 24 hours and the
/// reminders due by the end of the day. Nothing is asked of EventKit until a view that shows
/// the agenda appears; access is requested then, once, and the store keeps itself fresh with
/// the system's change notification plus a slow timer while such a view is on screen.
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

    /// A view that shows the agenda appeared. The first viewer asks for access.
    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        requestAccessIfNeeded()
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

    private func requestAccessIfNeeded() {
        guard !requested else { return }
        requested = true
        if eventsAccess == .notDetermined {
            store.requestFullAccessToEvents { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.eventsAccess = EKEventStore.authorizationStatus(for: .event)
                    self?.refresh()
                }
            }
        }
        if remindersAccess == .notDetermined {
            store.requestFullAccessToReminders { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
                    self?.refresh()
                }
            }
        }
    }

    var canReadEvents: Bool { eventsAccess == .fullAccess }
    var canReadReminders: Bool { remindersAccess == .fullAccess }

    // MARK: - Reading

    /// Asks for the day. Called on the main thread — from the timer, from the system's change
    /// notification, and from the button that has just ticked something off — and returns from
    /// it straight away, having handed the asking to the queue.
    func refresh() {
        // The gallery is handed its day rather than reading one, and this machine has no
        // calendar: refreshing here would only take the seeded day away again.
        guard !RenderMode.isGallery else { return }
        guard pass.start() else { return }
        // Both answers are read where they are shown, before anything leaves the main queue:
        // they are published properties, and a published property is main-thread-only.
        let wantsEvents = canReadEvents
        let wantsReminders = canReadReminders
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            let day = wantsEvents ? Self.dayEvents(in: self.store, at: now) : []
            guard wantsReminders else {
                self.publish(events: day, reminders: [])
                return
            }
            let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
            let predicate = self.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfDay, calendars: nil)
            // Answers on a queue of EventKit's own choosing, which is why the pass is not
            // finished until this half is in too.
            self.store.fetchReminders(matching: predicate) { [weak self] found in
                self?.publish(events: day, reminders: Self.dueReminders(from: found ?? []))
            }
        }
    }

    /// Where every reading lands, and the only place any of this is written: the main queue.
    private func publish(events: [Event], reminders: [Reminder]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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

    /// The next day's events, turned into something the panel can hold before they go
    /// anywhere near the main thread. An `EKEvent` belongs to the thread that fetched it, so
    /// the mapping happens here rather than on the other side of the hand-off.
    private static func dayEvents(in store: EKEventStore, at now: Date) -> [Event] {
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-5 * 60), end: now.addingTimeInterval(24 * 3600), calendars: nil)
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
                let da = a.dueDateComponents?.date ?? .distantFuture
                let db = b.dueDateComponents?.date ?? .distantFuture
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
        Event(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Event", start: e.startDate, end: e.endDate,
              isAllDay: e.isAllDay, location: e.location?.trimmingCharacters(in: .whitespacesAndNewlines),
              joinURL: CalendarMonitor.meetingLink(in: e), tint: tint(of: e.calendar))
    }

    private static func reminder(from r: EKReminder) -> Reminder {
        Reminder(id: r.calendarItemIdentifier, title: r.title ?? "Reminder", due: r.dueDateComponents?.date,
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
}
