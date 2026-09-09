import SwiftUI

/// Expanded view for third-party Live Activities pushed through the URL scheme / notchctl.
struct CustomExpandedView: View {
    let state: CustomActivity
    let activity: IslandActivity
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    private var tint: Color { Color.named(state.tint) }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                leadingSlot
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let subtitle = state.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    if let body = state.body, !body.isEmpty {
                        Text(body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                if let text = state.trailingText {
                    Text(text)
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if state.url != nil {
                    CircleActionButton(symbol: "arrow.up.forward", tint: .white) { activity.openAction?.perform() }
                }
            }
            .islandContentColumn()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            // A ring-less progress activity gets the bar under the header; one that asked for a
            // ring wears it in the leading slot instead, so the card stays one row tall.
            if let progress = state.progress, !state.showsRing {
                LevelBar(level: progress, tint: .white)
                    .frame(height: 4)
                    .islandContentColumn()
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, insidePanel ? 0 : 16)
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if let progress = state.progress, state.showsRing {
            ProgressRing(progress: progress, lineWidth: 3, tint: tint)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: state.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                )
                .accessibilityHidden(true)
        } else {
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Image(systemName: state.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
        }
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
