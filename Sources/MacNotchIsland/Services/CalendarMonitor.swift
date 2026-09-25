import AppKit
import Foundation
import EventKit

/// Shows the next calendar event as a Live Activity from ten minutes before it starts
/// until a few minutes after, with a Join button when a meeting link is found.
///
/// EventKit is never asked anything on the main thread. A calendar in an Exchange or CalDAV
/// account is not a file on this Mac, and `events(matching:)` can be a round trip to somebody's
/// server — the thing Today was fixed for, still happening here once a minute and on every
/// change notification, for as long as the app ran, with nothing on screen asking for it. The
/// reading happens on `queue`, the events are turned into plain values there, and only the
/// card is put up or taken down on the main thread.
final class CalendarMonitor: NSObject {
    private let store = EKEventStore()
    /// Where EventKit is asked. Serial, so a reset of the store after a grant lands ahead of
    /// the reading that needs it.
    private let queue = DispatchQueue(label: "com.macnotchisland.calendar", qos: .utility)
    /// One reading at a time, as Today keeps to: two in flight are two round trips for one
    /// answer, and the slower lands last carrying the older news. Main thread.
    private var pass = RadioPass()
    /// Which reading is the one still wanted. Bumped by every reading asked for and by
    /// `stop`, so an answer that comes back to a monitor that has since stopped — or been
    /// stopped and started again — is dropped rather than put up as a card. Main thread.
    private var reading = 0
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var authorized = false
    private var running = false

    /// How far ahead of its start an event is shown, and how long after its start it stays.
    static let leadTime: TimeInterval = 10 * 60
    static let linger: TimeInterval = 5 * 60

    func start() {
        guard !running else { return }
        running = true
        // Asked once, and the answer not kept: it is read again on every tick. Calendar access
        // is granted in System Settings whenever somebody gets round to it, and nothing tells
        // the app. Held from here, a refusal turned into a grant later never produced a card
        // until the app was relaunched, because the timer that would have noticed was only
        // ever started on a yes.
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.refresh()
            }
        }
        // Ten seconds either way costs nothing against a ten-minute lead, and lets the Mac
        // fold this wake into one it was making anyway.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Heard on the main queue whatever thread EventKit posts it from: `refresh` decides
        // what is shown, and that is the main thread's business.
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        // Whatever is in the air now answers nobody, and the gate it held goes with it.
        reading += 1
        pass = RadioPass()
        ActivityCenter.shared.end(id: "calendar")
    }

    /// Asks for the next event. Main thread, from the timer, the change notification and the
    /// answer to the permission prompt; returns at once, having handed the asking to `queue`.
    private func refresh() {
        guard running else { return }
        let granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        // A store made before the grant can go on seeing no calendars at all; starting it
        // afresh is what lets it see them. On the queue, ahead of the reading about to be
        // handed to it there.
        if granted && !authorized { queue.async { [weak self] in self?.store.reset() } }
        authorized = granted
        guard granted else {
            // Taken away while a card was up: the card goes with it.
            ActivityCenter.shared.end(id: "calendar")
            return
        }
        guard pass.start() else { return }
        reading += 1
        let answering = reading
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            let next = Self.nextEvent(in: self.store, at: now)
            DispatchQueue.main.async { [weak self] in self?.show(next, answering: answering) }
        }
    }

    /// Where every reading lands, and the only place the card is touched.
    private func show(_ next: CalendarState?, answering: Int) {
        // An answer to a reading nobody wants any more is not shown, and the gate it would
        // hand back was taken from it when it was given up.
        guard Self.answers(answering, current: reading) else { return }
        let again = pass.finish()
        // Access taken away while this was being read is as good as no event at all.
        if let state = next, authorized {
            var activity = IslandActivity(id: "calendar", kind: .calendar, content: .calendar(state), priority: 60)
            activity.expiresAt = state.start.addingTimeInterval(Self.linger)
            activity.openAction = state.joinURL.map { .url($0) } ?? .app(bundleID: "com.apple.iCal")
            ActivityCenter.shared.upsert(activity)
        } else {
            ActivityCenter.shared.end(id: "calendar")
        }
        // The store changed while this reading was in the air; the answer that matters is the
        // next one, not the one the minute's poll gets round to.
        if again { refresh() }
    }

    /// Whether an answer belongs to the reading still wanted. Pure, like Today's.
    static func answers(_ reading: Int, current: Int) -> Bool { reading == current }

    /// The event worth a card at `now`, read and turned into a plain value on the queue: an
    /// `EKEvent` belongs to the thread that fetched it, so nothing of it crosses to the main one.
    private static func nextEvent(in store: EKEventStore, at now: Date) -> CalendarState? {
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(60 * 60), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        guard let event = events.first(where: { isDue(start: $0.startDate, end: $0.endDate, at: now) }) else { return nil }
        let tint: String
        if let cg = event.calendar?.cgColor, let ns = NSColor(cgColor: cg) {
            tint = ns.hexString
        } else {
            tint = "blue"
        }
        return CalendarState(title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                             location: event.location, joinURL: meetingLink(in: event), tint: tint)
    }

    /// Whether an event is in its window for a card: starting within the lead time, not more
    /// than the linger past its start, and not over. Pure, so the edges can be tested.
    static func isDue(start: Date, end: Date, at now: Date) -> Bool {
        start.timeIntervalSince(now) <= leadTime && start.addingTimeInterval(linger) > now && end > now
    }

    static func meetingLink(in event: EKEvent) -> URL? {
        meetingLink(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " "))
    }

    /// The first video-call link in some text. Pure, so it can be tested without an event.
    static func meetingLink(in text: String) -> URL? {
        guard let regex = meetingPattern else { return nil }
        let haystack = text.replacingOccurrences(of: "\n", with: " ")
        let range = NSRange(haystack.startIndex..., in: haystack)
        guard let match = regex.firstMatch(in: haystack, range: range), let r = Range(match.range, in: haystack) else { return nil }
        return URL(string: String(haystack[r]))
    }

    /// Compiled once. It was compiled afresh for every event read, on every refresh here and
    /// for every row of Today — a regular expression built a dozen times a minute to be used
    /// once each. `NSRegularExpression` is immutable and safe to share between threads, which
    /// matters because both readers use it from their own queues.
    private static let meetingPattern = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"']*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|facetime\.apple\.com|whereby\.com)[^\s<>"']*"#,
        options: .caseInsensitive)
}
