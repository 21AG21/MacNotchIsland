import SwiftUI

struct DownloadExpandedView: View {
    let state: DownloadState
    let activity: IslandActivity
    let geometry: NotchGeometry

    private var tint: Color { state.isComplete ? Color.named("green") : Color.named("blue") }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.22))
                    Image(systemName: state.isComplete ? "checkmark" : "arrow.down")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(state.isComplete ? "Download complete · \(state.app)" : "\(state.sizeText) · \(state.app)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
                if let p = state.progress, !state.isComplete {
                    Text("\(Int((p * 100).rounded()))%")
                        .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                }
                if state.isComplete {
                    CircleActionButton(symbol: "arrow.up.forward", tint: tint, size: 36) { activity.openAction?.perform() }
                }
            }
            .padding(.horizontal, IslandInsets.horizontal)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            if let p = state.progress, !state.isComplete {
                LevelBar(level: p, tint: tint)
                    .frame(height: 5)
                    .padding(.horizontal, IslandInsets.horizontal)
                    .padding(.top, 10)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
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
