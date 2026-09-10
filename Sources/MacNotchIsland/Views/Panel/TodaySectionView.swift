import AppKit
import SwiftUI

/// What is left of the day: the next events with a Join button where there is a link, the
/// reminders due, and the weather in one line at the top.
struct TodaySectionView: View {
    @ObservedObject private var agenda = AgendaStore.shared
    @ObservedObject private var weather = WeatherService.shared
    @EnvironmentObject private var prefs: Preferences

    private static let eventRow: CGFloat = 36
    static let reminderRow: CGFloat = 28
    /// The gutter every row's leading mark stands in — an event's colour bar and a reminder's
    /// tick box alike — so both kinds of title start on the same line down the section. They
    /// used to start 13 pt apart.
    static let rail: CGFloat = 16
    /// The air between the parts of a row: the rail and the title, the title and the
    /// countdown, the countdown and the button. Named because the tick box's rectangle spends
    /// half of the first of them.
    static let rowGap: CGFloat = 10
    /// The countdown's column. Without it "in 1 hr" on a row with no Join button landed 44 pt
    /// right of "in 7 min" on the row above.
    private static let countdown: CGFloat = 62
    private static var listHeight: CGFloat { SectionMetrics.bodyHeight }

    // MARK: - What the tick box answers to

    /// The smallest thing the pointer is asked to hit anywhere in the app, which is Apple's
    /// floor for a control it drives and what the switcher's slots keep to: 28 pt. The tick
    /// box kept to 16, a target under a third of the area — on the one control in this section
    /// whose press cannot be taken back from here, since a reminder ticked off leaves the list
    /// and putting it back means opening Reminders.
    static let minHit: CGFloat = 28

    /// The rectangle it takes that click in. As wide as the pointer needs, and as tall, but
    /// never taller than the row it belongs to: a rectangle that reached past its own row
    /// would be sitting over the row above or below, both of which open Calendar when they are
    /// clicked, and a tick made in passing on the way to somewhere else is the one mistake
    /// this section must not invite.
    static var tickHit: CGSize {
        CGSize(width: max(rail, minHit), height: min(max(rail, minHit), reminderRow))
    }

    /// How far that reaches past the 16 pt the circle is drawn in, on each side — and what is
    /// taken straight off again, so none of it is laid out and not a pixel moves. Sideways it
    /// spends the margin the section already keeps to its leading edge and half the gap before
    /// the words, which leaves it stopping 4 pt short of them. Where anything in the row did
    /// come to lie under it the tick would win, being the row's own control and in front of
    /// everything else in it — which is exactly why it is given the empty air beside the rail
    /// and nothing more.
    static var tickInset: CGSize {
        CGSize(width: (tickHit.width - rail) / 2, height: (tickHit.height - rail) / 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            SectionHeader("Today") {
                if prefs.weatherEnabled { weatherLine }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The rest of the day, along the floor of the section: the space under three
            // appointments was the emptiest part of the panel, and what happens next outside
            // is the one thing a section called Today was missing.
            if prefs.weatherEnabled, !weather.hours.isEmpty { hourly }
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

    // MARK: - The next few hours

    /// Six hours across the width, each an hour, a glyph and a figure — the shape of every
    /// hourly forecast anybody has ever read.
    static let hourlyHeight: CGFloat = 40

    private var hourly: some View {
        HStack(spacing: 0) {
            ForEach(weather.hours) { hour in
                VStack(spacing: 1) {
                    Text(Self.hourLabel(hour.date))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Image(systemName: WeatherService.condition(code: hour.weatherCode, isDay: hour.isDay).symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(height: 14)
                    Text(WeatherService.formatTemperature(hour.temperatureC, fahrenheit: WeatherService.usesFahrenheit))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.hourLabel(hour.date)), \(WeatherService.formatTemperature(hour.temperatureC, fahrenheit: WeatherService.usesFahrenheit))")
            }
        }
        .frame(height: Self.hourlyHeight)
        .accessibilityElement(children: .contain)
    }

    /// "17", or "5 PM" where the clock is a twelve-hour one — the machine's own preference,
    /// asked once per hour rather than formatted per cell.
    static func hourLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        guard let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current),
              template.contains("h") || template.contains("K") else {
            return "\(hour)"
        }
        let suffix = hour < 12 ? "AM" : "PM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve) \(suffix)"
    }

    // MARK: - Weather, in one line

    @ViewBuilder
    private var weatherLine: some View {
        if let celsius = weather.temperatureC {
            HStack(spacing: 5) {
                Image(systemName: weather.conditionSymbol)
                    .font(.system(size: 11, weight: .semibold))
                // The separator the rest of the app uses between two facts on one line, in
                // place of the two spaces that stood here.
                Text(WeatherService.formatTemperature(celsius, fahrenheit: WeatherService.usesFahrenheit)
                     + (weather.conditionText.isEmpty ? "" : " · " + weather.conditionText))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityElement(children: .combine)
        } else if weather.state == .denied {
            // A switch somebody turned on and that then shows nothing at all is
            // indistinguishable from one that does not work. Location is the one thing the
            // weather cannot do without, and this is the same offer the Windows section makes
            // for the permissions it needs.
            PillButton(title: "Allow Location", tint: .white.opacity(0.85)) {
                SystemSettingsPane.location.open()
            }
            .accessibilityLabel(Text("Weather needs your location. Open Location Services."))
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

    /// Whether anything on screen can be joined, and so whether the trailing column exists.
    private var showsJoinColumn: Bool {
        rows.contains { row in
            if case .event(let event) = row { return event.joinURL != nil }
            return false
        }
    }

    /// The trailing action column. Every row carries it once anything on screen can be
    /// joined, so the countdowns beside it line up instead of one of them stepping 74 pt
    /// sideways at the single row you can act on; a row with nothing to join lays the button
    /// out and leaves it invisible, which is also how the column stays exactly as wide as the
    /// button in every language rather than as wide as a number somebody guessed.
    @ViewBuilder
    private func joinColumn(_ url: URL?) -> some View {
        if showsJoinColumn {
            PillButton(title: "Join", symbol: "video.fill", tint: Color.named("green"), prominent: true) {
                if let url { NSWorkspace.shared.open(url) }
            }
            // A row's control, at the size a row's controls are. At the full size it was the
            // largest thing on the section and the only saturated one — a web page's call to
            // action sitting in a list of appointments.
            .environment(\.islandCompactControls, true)
            .opacity(url == nil ? 0 : 1)
            .allowsHitTesting(url != nil)
            .accessibilityHidden(url == nil)
        }
    }

    /// A row is a button, and was a tap gesture: a thing only a pointer can find. VoiceOver
    /// read the appointment out and then offered nothing to be done with it, and Return did
    /// nothing at all, because a rectangle with a gesture on it is not a control. Same style
    /// the rest of the app puts on a row you can press, so nothing about it looks any
    /// different until it is pressed.
    private func eventRow(_ event: AgendaStore.Event) -> some View {
        let tint = Color.named(event.tint)
        return HStack(spacing: Self.rowGap) {
            Button(action: { OpenAction.app(bundleID: "com.apple.iCal").perform() }) {
                HStack(spacing: Self.rowGap) {
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
                }
                .frame(height: Self.eventRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle())
            // What is read out, rather than the four separate scraps the row is drawn from.
            // The countdown is left out of it on purpose: it is written by a timeline that
            // redraws every half minute, and a label that does not go with it would be
            // announcing a number that stopped being true some minutes ago.
            .accessibilityLabel(Text("\(event.title), \(Self.timeRange(event))"))
            .accessibilityHint(Text("Opens Calendar"))
            // Outside the button rather than in it: one control inside another is two answers
            // to one click, and the wrong one of them opens Calendar over the meeting somebody
            // was trying to join.
            joinColumn(event.joinURL)
        }
        .frame(height: Self.eventRow)
    }

    private func reminderRow(_ reminder: AgendaStore.Reminder) -> some View {
        HStack(spacing: Self.rowGap) {
            Button(action: { agenda.setCompleted(true, reminderID: reminder.id) }) {
                Circle()
                    .strokeBorder(Color.named(reminder.tint), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .frame(width: Self.rail, height: Self.rail, alignment: .leading)
                    // Out to the size the pointer is owed and straight back in again. The
                    // rectangle in the middle is what takes the click; the padding either side
                    // of it cancels, so the circle is drawn where it always was and the title
                    // beside it does not move a point.
                    .padding(.horizontal, Self.tickInset.width)
                    .padding(.vertical, Self.tickInset.height)
                    .contentShape(Rectangle())
                    .padding(.horizontal, -Self.tickInset.width)
                    .padding(.vertical, -Self.tickInset.height)
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
            joinColumn(nil)
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
