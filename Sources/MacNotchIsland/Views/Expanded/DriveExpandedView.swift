import SwiftUI

/// A disk's card: what it is called, how full it is, and the button that gets it out safely.
///
/// The reason people pull a drive out without ejecting it is that ejecting it means finding
/// its icon on a desktop that is under everything else. Here it is on the thing that just told
/// them the drive arrived.
struct DriveExpandedView: View {
    let state: DriveState
    let activity: IslandActivity
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    private var tint: Color { Color.named(state.tint) }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.18))
                    Image(systemName: state.symbol)
                        .font(.system(size: 19, weight: .semibold))
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
                    Text(state.subtitle)
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                controls
            }
            .islandContentColumn()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(state.name), \(state.subtitle)")
            if let fill = state.fill {
                LevelBar(level: fill, tint: .white)
                    .frame(height: 4)
                    .islandContentColumn()
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, insidePanel ? 0 : 16)
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }

    /// Open it, and get it out. Neither is offered once the disk has gone: there is nothing
    /// left to open and nothing left to eject.
    @ViewBuilder
    private var controls: some View {
        if state.event == .connected || state.event == .busy {
            HStack(spacing: 10) {
                CircleActionButton(symbol: "folder", tint: .white, label: "Open \(state.name)") {
                    activity.openAction?.perform()
                }
                if state.isEjectable {
                    CircleActionButton(symbol: "eject.fill", tint: tint, label: "Eject \(state.name)") {
                        VolumeMonitor.shared.eject(state)
                    }
                }
            }
        }
    }
}
