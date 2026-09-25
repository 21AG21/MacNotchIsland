import AppKit
import SwiftUI

/// What is left of the day: the next events with a Join button where there is a link, the
/// reminders due, and the weather in one line at the top.
struct TodaySectionView: View {
    @ObservedObject private var agenda = AgendaStore.shared
    @ObservedObject private var weather = WeatherService.shared
    @EnvironmentObject private var prefs: Preferences
    /// Whether this view holds one of the weather's claims, see `holdWeather`.
    @State private var holdsWeather = false

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

    /// The room the rows are counted against. The whole body with the weather off; with the
    /// hours along the floor, what they and the gap above them leave. The strip came after the
    /// list and the list went on counting the whole body, so two events and a reminder — 100 pt
    /// of rows — were laid out over 62 pt of room and the hours were pushed off the bottom of
    /// the section.
    static func listHeight(showingHours: Bool) -> CGFloat {
        SectionMetrics.bodyHeight - (showingHours ? hourlyHeight + SectionMetrics.gapBelowHeader : 0)
    }

    /// Whether the hours go along the floor: the weather is on, and there is a forecast young
    /// enough to show and hours of it still to come. A forecast too old for its reading to be
    /// shown is too old for its hours as well.
    static func showsHours(weatherOn: Bool, weather: WeatherService, at now: Date = Date()) -> Bool {
        weatherOn && weather.state != .denied && weather.age(at: now) != .expired
            && !WeatherService.upcoming(weather.hours, after: now).isEmpty
    }

    private var showsHours: Bool { Self.showsHours(weatherOn: prefs.weatherEnabled, weather: weather) }
    private var listHeight: CGFloat { Self.listHeight(showingHours: showsHours) }

    /// How many events and reminders go into that room, and how many are left out of it:
    /// events first and at most three, then reminders, each only if the whole row fits. A row
    /// that does not fit is not drawn half over the hours.
    ///
    /// What is left out is counted rather than dropped. With the weather on there is room for
    /// one event and nothing else, and a second event or every reminder of the day went
    /// missing without a word; the count is what goes in the header ("Today · 2 more"), and
    /// what turns the list into one that scrolls.
    static func fit(events: Int, reminders: Int, in height: CGFloat) -> (events: Int, reminders: Int, left: Int) {
        var used: CGFloat = 0
        var shownEvents = 0
        while shownEvents < min(events, 3), used + eventRow <= height {
            shownEvents += 1
            used += eventRow
        }
        var shownReminders = 0
        while shownReminders < reminders, used + reminderRow <= height {
            shownReminders += 1
            used += reminderRow
        }
        return (shownEvents, shownReminders, (events - shownEvents) + (reminders - shownReminders))
    }

    /// The section's title, carrying what the room left out: the one place on screen that
    /// says there is more of the day than is in view.
    static func title(left: Int) -> String {
        left > 0 ? "Today · \(left) more" : "Today"
    }

    /// Today's events and the reminders still open — all of them, in the order the list
    /// shows them. "Today" ends at the next midnight by the calendar, see
    /// `AgendaStore.endOfDay(for:calendar:)`.
    static func day(events: [AgendaStore.Event], reminders: [AgendaStore.Reminder], at now: Date,
                    calendar: Calendar = .current) -> (events: [AgendaStore.Event], reminders: [AgendaStore.Reminder]) {
        let end = AgendaStore.endOfDay(for: now, calendar: calendar)
        return (events.filter { $0.start < end }, reminders.filter { !$0.isCompleted })
    }

    /// Whether the calendar has been refused, which puts its own empty state where the list
    /// would be. Not the same as "cannot read events": a Mac that has not been asked yet is
    /// about to be, and meanwhile shows whatever reminders it can read as a list.
    static func calendarOff(_ agenda: AgendaStore) -> Bool {
        !agenda.canReadEvents && agenda.eventsAccess != .notDetermined
    }

    /// Whether the body is the list of the day, rather than the calendar's refusal or the
    /// day's empty state: the calendar not refused, and a row of the day to put in it. Pure,
    /// so the rule is tested.
    static func showsList(calendarOff: Bool, rows: Int) -> Bool {
        !calendarOff && rows > 0
    }

    /// What the header counts as left out, and so whether the list scrolls: what `fit` left
    /// out of the room, while the list is what is on screen, and nothing otherwise.
    ///
    /// Counted from the day alone, "N more" went on being said over the calendar's refusal.
    /// With Calendars refused, Reminders allowed and the weather on, three reminders read
    /// "Today · 1 more" above "Calendar access is off", and a scroll there — the section
    /// counted as one that scrolls — neither scrolled nor changed the volume.
    static func leftOut(events: Int, reminders: Int, in height: CGFloat, calendarOff: Bool) -> Int {
        guard showsList(calendarOff: calendarOff, rows: events + reminders) else { return 0 }
        return fit(events: events, reminders: reminders, in: height).left
    }

    /// Whether there is more of the day than the room shows, and so a list that scrolls. Read
    /// from the stores themselves, so that whatever decides where a scroll goes can ask it of
    /// a section it cannot see into.
    static var overflows: Bool {
        let agenda = AgendaStore.shared
        let today = day(events: agenda.events, reminders: agenda.reminders, at: Date())
        let hours = showsHours(weatherOn: Preferences.shared.weatherEnabled, weather: WeatherService.shared)
        return leftOut(events: today.events.count, reminders: today.reminders.count,
                       in: listHeight(showingHours: hours), calendarOff: calendarOff(agenda)) > 0
    }

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
            SectionHeader(Self.title(left: layout.left)) {
                if prefs.weatherEnabled { weatherLine }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The rest of the day, along the floor of the section: the space under three
            // appointments was the emptiest part of the panel, and what happens next outside
            // is the one thing a section called Today was missing.
            if showsHours { hourly }
        }
        .onAppear {
            agenda.viewerAppeared()
            holdWeather(prefs.weatherEnabled)
        }
        .onDisappear {
            agenda.viewerDisappeared()
            holdWeather(false)
        }
        .onChange(of: prefs.weatherEnabled) { _, on in holdWeather(on) }
    }

    /// Takes or gives back this view's claim on the weather. What it gives back on the way out
    /// is what it took, rather than what the switch says by then: turning Weather off with
    /// Today on screen skipped the `stop()`, and the service went on polling with its switch
    /// off for the rest of the session.
    private func holdWeather(_ wanted: Bool) {
        guard wanted != holdsWeather else { return }
        holdsWeather = wanted
        if wanted { weather.start() } else { weather.stop() }
    }

    // MARK: - The next few hours

    /// Six hours across the width, each an hour, a glyph and a figure — the shape of every
    /// hourly forecast anybody has ever read. The three lines and the two points between them
    /// come to about 41 pt, which a 40 pt strip clipped.
    static let hourlyHeight: CGFloat = 42

    private var hourly: some View {
        HStack(spacing: 0) {
            ForEach(weather.upcomingHours) { hour in
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

    /// The refusal first, then the reading. The other way about, a reading cached before
    /// Location was refused stood in the line for good and the offer below never appeared.
    @ViewBuilder
    private var weatherLine: some View {
        if weather.state == .denied {
            // A switch somebody turned on and that then shows nothing at all is
            // indistinguishable from one that does not work. Location is the one thing the
            // weather cannot do without, and this is the same offer the Windows section makes
            // for the permissions it needs.
            PillButton(title: "Allow Location", tint: .white.opacity(0.85)) {
                SystemSettingsPane.location.open()
            }
            .accessibilityLabel(Text("Weather needs your location. Open Location Services."))
        } else {
            // Redrawn each minute, so a reading that goes on being the last one there is
            // starts saying how old it is while the panel is open, not only the next time.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                reading(at: context.date)
            }
        }
    }

    @ViewBuilder
    private func reading(at now: Date) -> some View {
        if let celsius = weather.temperatureC,
           let line = Self.weatherText(celsius: celsius, condition: weather.conditionText,
                                       age: weather.age(at: now), fahrenheit: WeatherService.usesFahrenheit) {
            HStack(spacing: 5) {
                Image(systemName: weather.conditionSymbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(line)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityElement(children: .combine)
        }
    }

    /// "18° · Clear", with how long ago it was true once that is worth saying — "18° · Clear
    /// · 3 hrs ago" — and nothing at all for a reading too old to be the weather. The
    /// separator is the one the rest of the app uses between two facts on one line.
    static func weatherText(celsius: Double, condition: String, age: WeatherService.Age,
                            fahrenheit: Bool) -> String? {
        var parts = [WeatherService.formatTemperature(celsius, fahrenheit: fahrenheit)]
        if !condition.isEmpty { parts.append(condition) }
        switch age {
        case .current: break
        case .old(let ago): parts.append(ago)
        case .expired: return nil
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if Self.calendarOff(agenda) {
            SectionEmptyState(symbol: "calendar.badge.exclamationmark", title: "Calendar access is off",
                              subtitle: "Allow Calendars for Notch Island to see your day here.") {
                PillButton(title: "Open Settings", symbol: "gearshape.fill") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else if rows.isEmpty {
            // "Nothing left" is only true of what can be read: with the reminders refused it
            // is the events that are done, and the title says which.
            SectionEmptyState(symbol: "calendar",
                              title: remindersRefused ? "No events left today" : "Nothing left today",
                              subtitle: tomorrowHint) {
                if remindersRefused { remindersPill }
            }
        } else if layout.left > 0 {
            // More of the day than the room: all of it, in a list that scrolls, with the
            // header saying how much is out of view. The rows at the top are the ones `fit`
            // would have shown, so nothing moves when the list stops fitting.
            IslandScrollStrip(axis: .vertical) {
                list(withNote: remindersRefused)
            }
        } else {
            list(withNote: remindersRefused && remindersNoteFits)
        }
    }

    private func list(withNote note: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                switch row {
                case .event(let event): eventRow(event)
                case .reminder(let reminder): reminderRow(reminder)
                }
            }
            if note { remindersNote }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Reminders that cannot be read

    /// Whether Reminders has been refused while Calendars was allowed.
    ///
    /// Only that case: a Mac that has not been asked yet is about to be, and one that refused
    /// the calendar too is shown the calendar's own empty state above, which covers both. The
    /// pane promises "events and reminders", and a list of events with "nothing left" under
    /// it was what a refused permission looked like from the outside — nothing to say the
    /// reminders were missing, and nowhere to go to put it right.
    private var remindersRefused: Bool {
        agenda.canReadEvents && !agenda.canReadReminders && agenda.remindersAccess != .notDetermined
    }

    /// Whether there is a reminder's row of room under the events. The rule the reminders
    /// themselves keep: three events fill the section, and where no reminder would have
    /// fitted, neither does a line about them.
    private var remindersNoteFits: Bool {
        rows.reduce(0) { $0 + $1.height } + Self.reminderRow <= listHeight
    }

    /// The same offer the weather makes for its location, to the pane that decides it.
    private var remindersPill: some View {
        PillButton(title: "Allow Reminders", tint: .white.opacity(0.85)) {
            SystemSettingsPane.reminders.open()
        }
        .accessibilityLabel(Text("Reminders access is off. Open Reminders privacy settings."))
    }

    /// The line the first reminder would have stood on, saying why none does. Laid out the
    /// way a reminder is — the rail, the title, the trailing column — so it reads as the row
    /// it stands in for rather than as a banner over the list.
    private var remindersNote: some View {
        HStack(spacing: Self.rowGap) {
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: Self.rail, alignment: .leading)
                .accessibilityHidden(true)
            Text("Reminders access is off")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 8)
            remindersPill
                .environment(\.islandCompactControls, true)
        }
        .frame(height: Self.reminderRow)
        .accessibilityElement(children: .contain)
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

    /// The day, and how much of it the room holds — see `fit`, and `leftOut` for why nothing
    /// is counted as left out while the list is not what is on screen.
    private var layout: (events: [AgendaStore.Event], reminders: [AgendaStore.Reminder], left: Int) {
        let today = Self.day(events: agenda.events, reminders: agenda.reminders, at: Date())
        let left = Self.leftOut(events: today.events.count, reminders: today.reminders.count, in: listHeight,
                                calendarOff: Self.calendarOff(agenda))
        return (today.events, today.reminders, left)
    }

    /// Today's events first, then reminders: as many as fit (at most three events), or every
    /// one of them in a list that scrolls when the room cannot hold them all.
    private var rows: [Row] {
        let day = layout
        if day.left > 0 { return day.events.map(Row.event) + day.reminders.map(Row.reminder) }
        let shown = Self.fit(events: day.events.count, reminders: day.reminders.count, in: listHeight)
        return day.events.prefix(shown.events).map(Row.event) + day.reminders.prefix(shown.reminders).map(Row.reminder)
    }

    private var tomorrowHint: String? {
        let endOfDay = AgendaStore.endOfDay(for: Date())
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
