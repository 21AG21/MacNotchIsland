import SwiftUI

struct DownloadExpandedView: View {
    let state: DownloadState
    let activity: IslandActivity
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    private var tint: Color { state.isComplete ? Color.named("green") : Color.named("blue") }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.18))
                    Image(systemName: state.isComplete ? "checkmark" : "arrow.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.isComplete ? "Download complete · \(state.app)" : "\(state.sizeText) · \(state.app)")
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if let p = state.progress, !state.isComplete {
                    Text("\(Int((p * 100).rounded()))%")
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                if state.isComplete {
                    CircleActionButton(symbol: "arrow.up.forward", tint: .white) { activity.openAction?.perform() }
                }
            }
            .islandContentColumn()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            if let p = state.progress, !state.isComplete {
                LevelBar(level: p, tint: .white)
                    .frame(height: 4)
                    .islandContentColumn()
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, insidePanel ? 0 : 16)
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }

    /// "notch-island.dmg, Download complete, Safari" (or the in-progress size and, while it
    /// has a known total, the percent) — the row as one sentence; the Open button stays
    /// reachable underneath once the download finishes.
    private var accessibilitySummary: String {
        var parts = [state.name]
        parts.append(state.isComplete ? "Download complete, \(state.app)" : "\(state.sizeText), \(state.app)")
        if let p = state.progress, !state.isComplete {
            parts.append("\(Int((p * 100).rounded())) percent")
        }
        return parts.joined(separator: ", ")
    }
}
