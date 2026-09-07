import SwiftUI

struct DownloadExpandedView: View {
    let state: DownloadState
    let activity: IslandActivity
    let geometry: NotchGeometry

    private var tint: Color { state.isComplete ? Color(red: 0.2, green: 0.84, blue: 0.29) : Color(red: 0.04, green: 0.52, blue: 1) }

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
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(state.isComplete ? "Download complete · \(state.app)" : "\(state.sizeText) · \(state.app)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
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
            .padding(.horizontal, 22)
            if let p = state.progress, !state.isComplete {
                LevelBar(level: p, tint: tint)
                    .frame(height: 5)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
    }
}
