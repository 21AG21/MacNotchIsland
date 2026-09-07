import SwiftUI

/// Expanded view for third-party Live Activities pushed through the URL scheme / notchctl.
struct CustomExpandedView: View {
    let state: CustomActivity
    let activity: IslandActivity
    let geometry: NotchGeometry

    private var tint: Color { Color.named(state.tint) }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.22))
                    Image(systemName: state.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let subtitle = state.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    if let body = state.body, !body.isEmpty {
                        Text(body).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                    }
                }
                Spacer()
                if let text = state.trailingText {
                    Text(text)
                        .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                }
                if state.url != nil {
                    CircleActionButton(symbol: "arrow.up.forward", tint: tint, size: 36) { activity.openAction?.perform() }
                }
            }
            .padding(.horizontal, 22)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            if let progress = state.progress {
                LevelBar(level: progress, tint: tint)
                    .frame(height: 5)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
    }

    /// The title plus whatever of subtitle / body / trailing text this activity set, as one
    /// sentence; the Open button (when there is a URL) stays reachable underneath.
    private var accessibilitySummary: String {
        var parts = [state.title]
        if let subtitle = state.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if let body = state.body, !body.isEmpty { parts.append(body) }
        if let text = state.trailingText { parts.append(text) }
        return parts.joined(separator: ", ")
    }
}
