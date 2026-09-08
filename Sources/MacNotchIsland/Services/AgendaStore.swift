import AppKit
import Combine
import EventKit
import Foundation

/// Today, for the Home panel: the calendar events still ahead in the next 24 hours and the
/// reminders due by the end of the day. Nothing is asked of EventKit until a view that shows
/// the agenda appears; access is requested then, once, and the store keeps itself fresh with
/// the system's change notification plus a slow timer while such a view is on screen.
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
    private var viewers = 0
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var requested = false

    private init() {}

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

    func refresh() {
        let now = Date()
        if canReadEvents {
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-5 * 60), end: now.addingTimeInterval(24 * 3600), calendars: nil)
            let fetched = store.events(matching: predicate)
                .filter { $0.status != .canceled && $0.endDate > now }
                .sorted { a, b in
                    if a.isAllDay != b.isAllDay { return !a.isAllDay }
                    return a.startDate < b.startDate
                }
                .prefix(12)
                .map(Self.event(from:))
            if fetched != events { events = fetched }
        } else if !events.isEmpty {
            events = []
        }

        if canReadReminders {
            let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfDay, calendars: nil)
            store.fetchReminders(matching: predicate) { [weak self] found in
                let list = (found ?? [])
                    .sorted { a, b in
                        let da = a.dueDateComponents?.date ?? .distantFuture
                        let db = b.dueDateComponents?.date ?? .distantFuture
                        if da != db { return da < db }
                        return a.priority < b.priority
                    }
                    .prefix(12)
                    .map(Self.reminder(from:))
                DispatchQueue.main.async {
                    guard let self else { return }
                    if list != self.reminders { self.reminders = list }
                }
            }
        } else if !reminders.isEmpty {
            reminders = []
        }
    }

    /// Ticks a reminder off (or back on) in Reminders itself.
    func setCompleted(_ completed: Bool, reminderID: String) {
        guard let item = store.calendarItem(withIdentifier: reminderID) as? EKReminder else { return }
        item.isCompleted = completed
        try? store.save(item, commit: true)
        refresh()
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
