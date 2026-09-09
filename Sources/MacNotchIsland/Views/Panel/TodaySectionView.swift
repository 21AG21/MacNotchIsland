import AppKit
import SwiftUI

/// What is left of the day: the next events with a Join button where there is a link, the
/// reminders due, and the weather in one line at the top.
struct TodaySectionView: View {
    @ObservedObject private var agenda = AgendaStore.shared
    @ObservedObject private var weather = WeatherService.shared
    @EnvironmentObject private var prefs: Preferences

    private static let eventRow: CGFloat = 36
    private static let reminderRow: CGFloat = 28
    /// The gutter every row's leading mark stands in — an event's colour bar and a reminder's
    /// tick box alike — so both kinds of title start on the same line down the section. They
    /// used to start 13 pt apart.
    private static let rail: CGFloat = 16
    /// The countdown's column. Without it "in 1 hr" on a row with no Join button landed 44 pt
    /// right of "in 7 min" on the row above.
    private static let countdown: CGFloat = 62
    private static var listHeight: CGFloat { SectionMetrics.bodyHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            SectionHeader("Today") {
                if prefs.weatherEnabled { weatherLine }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            agenda.viewerAppeared()
            if prefs.weatherEnabled { weather.start() }
        }
        .onDisappear {
            agenda.viewerDisappeared()
            if prefs.weatherEnabled { weather.stop() }
        }
    }

    // MARK: - Weather, in one line

    @ViewBuilder
    private var weatherLine: some View {
        if let celsius = weather.temperatureC {
            HStack(spacing: 5) {
                Image(systemName: weather.conditionSymbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(WeatherService.formatTemperature(celsius, usesMetric: WeatherService.usesMetric)
                     + (weather.conditionText.isEmpty ? "" : "  " + weather.conditionText))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityElement(children: .combine)
        } else if weather.state == .denied {
            EmptyView()
        }
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if !agenda.canReadEvents, agenda.eventsAccess != .notDetermined {
            SectionEmptyState(symbol: "calendar.badge.exclamationmark", title: "Calendar access is off",
                              subtitle: "Allow Calendars for Notch Island to see your day here.") {
                PillButton(title: "Open Settings", symbol: "gearshape.fill") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else if rows.isEmpty {
            SectionEmptyState(symbol: "calendar", title: "Nothing left today", subtitle: tomorrowHint)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    switch row {
                    case .event(let event): eventRow(event)
                    case .reminder(let reminder): reminderRow(reminder)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private enum Row: Identifiable {
        case event(AgendaStore.Event)
        case reminder(AgendaStore.Reminder)
        var id: String {
            switch self {
            case .event(let e): return "e-" + e.id
            case .reminder(let r): return "r-" + r.id
            }
        }
        var height: CGFloat {
            switch self {
            case .event: return TodaySectionView.eventRow
            case .reminder: return TodaySectionView.reminderRow
            }
        }
    }

    /// Today's events first (at most three), then reminders, as many as fit.
    private var rows: [Row] {
        let now = Date()
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        var result: [Row] = agenda.events.filter { $0.start < endOfDay }.prefix(3).map(Row.event)
        var used = result.reduce(0) { $0 + $1.height }
        for reminder in agenda.reminders where !reminder.isCompleted {
            guard used + Self.reminderRow <= Self.listHeight else { break }
            result.append(.reminder(reminder))
            used += Self.reminderRow
        }
        return result
    }

    private var tomorrowHint: String? {
        let endOfDay = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600)
        guard let next = agenda.events.first(where: { $0.start >= endOfDay }) else { return nil }
        return "Tomorrow: \(next.title) at \(AgendaStore.timeLabel(for: next))"
    }

    // MARK: - Rows

    private func eventRow(_ event: AgendaStore.Event) -> some View {
        let tint = Color.named(event.tint)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3, height: 24)
                .frame(width: Self.rail, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(Self.timeRange(event))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.countdown(event, at: context.date))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .frame(minWidth: Self.countdown, alignment: .trailing)
            }
            if let url = event.joinURL {
                PillButton(title: "Join", symbol: "video.fill", tint: Color.named("green"), prominent: true) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .frame(height: Self.eventRow)
        .contentShape(Rectangle())
        .onTapGesture { OpenAction.app(bundleID: "com.apple.iCal").perform() }
        .accessibilityElement(children: .combine)
    }

    private func reminderRow(_ reminder: AgendaStore.Reminder) -> some View {
        HStack(spacing: 10) {
            Button(action: { agenda.setCompleted(true, reminderID: reminder.id) }) {
                Circle()
                    .strokeBorder(Color.named(reminder.tint), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .frame(width: Self.rail, height: Self.rail, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("Complete \(reminder.title)")
            Text(reminder.title)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let due = AgendaStore.dueLabel(for: reminder) {
                Text(due)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(due == "Overdue" ? Color.named("red") : .white.opacity(0.45))
                    .lineLimit(1)
                    .frame(minWidth: Self.countdown, alignment: .trailing)
            }
        }
        .frame(height: Self.reminderRow)
        .accessibilityElement(children: .contain)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func timeRange(_ event: AgendaStore.Event) -> String {
        if event.isAllDay { return "All day" }
        return timeFormatter.string(from: event.start) + " – " + timeFormatter.string(from: event.end)
    }

    static func countdown(_ event: AgendaStore.Event, at now: Date) -> String {
        if event.isAllDay { return "" }
        let delta = event.start.timeIntervalSince(now)
        if delta <= 0 { return event.end > now ? "Now" : "Ended" }
        let minutes = Int((delta / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        return hours == 1 ? "in 1 hr" : "in \(hours) hrs"
    }
}
