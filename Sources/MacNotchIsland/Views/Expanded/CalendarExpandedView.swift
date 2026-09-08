import SwiftUI

struct CalendarExpandedView: View {
    let state: CalendarState
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var tint: Color { Color.named(state.tint) }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.18))
                    Image(systemName: "calendar")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(Self.time.string(from: state.start)) – \(Self.time.string(from: state.end))")
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    // The countdown sits under the time rather than shouting in the tint.
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(countdown(at: ctx.date))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if let url = state.joinURL {
                    PillButton(title: "Join", tint: Color.named("green"), prominent: true) {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    PillButton(title: "Open", tint: .white) {
                        OpenAction.app(bundleID: "com.apple.iCal").perform()
                    }
                }
            }
            .padding(.horizontal, IslandInsets.horizontal)
            .padding(.bottom, 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }

    /// The compact pill's "in 7m", spelled out for the card: "in 7 min", "in 2 hr", "Now".
    private func countdown(at date: Date) -> String {
        let delta = state.start.timeIntervalSince(date)
        guard delta > 0 else { return state.end.timeIntervalSince(date) > 0 ? "Now" : "Ended" }
        let minutes = Int((delta / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        return "in \(minutes / 60) hr"
    }

    /// "Team standup, 10:00 AM to 10:30 AM, Room 2" — the whole card as one sentence; the
    /// Join/Open button stays reachable underneath as its own element.
    private var accessibilitySummary: String {
        var parts = [state.title, "\(Self.time.string(from: state.start)) to \(Self.time.string(from: state.end))"]
        if let location = state.location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: ", ")
    }
}
