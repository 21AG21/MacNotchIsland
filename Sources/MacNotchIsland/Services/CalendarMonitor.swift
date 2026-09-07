import AppKit
import Foundation
import EventKit

/// Shows the next calendar event as a Live Activity from ten minutes before it starts
/// until a few minutes after, with a Join button when a meeting link is found.
final class CalendarMonitor: NSObject {
    private let store = EKEventStore()
    private var timer: Timer?
    private var authorized = false
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.authorized = granted
                guard granted else { return }
                self.refresh()
                self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
                NotificationCenter.default.addObserver(self, selector: #selector(self.storeChanged), name: .EKEventStoreChanged, object: self.store)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        ActivityCenter.shared.end(id: "calendar")
    }

    @objc private func storeChanged() { refresh() }

    private func refresh() {
        guard authorized else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(60 * 60), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }

        let leadTime: TimeInterval = 10 * 60
        let linger: TimeInterval = 5 * 60
        guard let event = events.first(where: { e in
            e.startDate.timeIntervalSince(now) <= leadTime && e.startDate.addingTimeInterval(linger) > now && e.endDate > now
        }) else {
            ActivityCenter.shared.end(id: "calendar")
            return
        }

        let tint: String
        if let cg = event.calendar?.cgColor, let ns = NSColor(cgColor: cg) {
            tint = ns.hexString
        } else {
            tint = "blue"
        }
        let state = CalendarState(title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                                  location: event.location, joinURL: Self.meetingLink(in: event), tint: tint)
        var activity = IslandActivity(id: "calendar", kind: .calendar, content: .calendar(state), priority: 60)
        activity.expiresAt = event.startDate.addingTimeInterval(linger)
        activity.openAction = state.joinURL.map { .url($0) } ?? .app(bundleID: "com.apple.iCal")
        ActivityCenter.shared.upsert(activity)
    }

    private static func meetingLink(in event: EKEvent) -> URL? {
        var haystack = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        haystack = haystack.replacingOccurrences(of: "\n", with: " ")
        let pattern = #"https?://[^\s<>"']*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|facetime\.apple\.com|whereby\.com)[^\s<>"']*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(haystack.startIndex..., in: haystack)
        guard let match = regex.firstMatch(in: haystack, range: range), let r = Range(match.range, in: haystack) else { return nil }
        return URL(string: String(haystack[r]))
    }
}
