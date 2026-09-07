import SwiftUI

struct CalendarExpandedView: View {
    let state: CalendarState
    let geometry: NotchGeometry

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.named(state.tint))
                    .frame(width: 4, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(Self.time.string(from: state.start)) – \(Self.time.string(from: state.end))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                    if let location = state.location, !location.isEmpty {
                        Text(location).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(state.relativeStart(at: ctx.date))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.named(state.tint))
                }
                if let url = state.joinURL {
                    PillButton(title: "Join", symbol: "video.fill", tint: .white, prominent: true) { NSWorkspace.shared.open(url) }
                } else {
                    PillButton(title: "Open", tint: .white) {
                        OpenAction.app(bundleID: "com.apple.iCal").perform()
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    /// "Team standup, 10:00 AM to 10:30 AM, Room 2" — the whole card as one sentence; the
    /// countdown and Join/Open button stay reachable underneath as their own elements.
    private var accessibilitySummary: String {
        var parts = [state.title, "\(Self.time.string(from: state.start)) to \(Self.time.string(from: state.end))"]
        if let location = state.location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: ", ")
    }
}
