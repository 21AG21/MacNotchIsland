import SwiftUI

struct CallExpandedView: View {
    let state: CallState
    let activity: IslandActivity
    let geometry: NotchGeometry

    private var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: state.bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(spacing: 14) {
                // One stable container for both branches, so the matched group keeps its member
                // whether or not the app icon resolves.
                ZStack {
                    if let icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Circle().fill(Color.green.opacity(0.25))
                        Image(systemName: "phone.fill").foregroundStyle(.green)
                    }
                }
                .frame(width: 44, height: 44)
                .islandMatched(IslandMatchedID.callGlyph)
                .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.appName).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            Text("Call in progress").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Text(ctx.date.timeIntervalSince(state.startedAt).mmss)
                            .font(.system(size: 20, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.green)
                            .contentTransition(.numericText(countsDown: false))
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .islandMatched(IslandMatchedID.callTime)
                    }
                    // Name, status and the ticking digits read as one sentence; the Open button
                    // beside them keeps its own label.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenLabel(at: ctx.date))
                }
                CircleActionButton(symbol: "arrow.up.forward", tint: .green, label: "Open \(state.appName)") {
                    activity.openAction?.perform()
                }
            }
            .padding(.horizontal, IslandInsets.horizontal)
            .padding(.bottom, 14)
        }
    }

    /// "FaceTime call, 4 minutes 12 seconds".
    private func spokenLabel(at date: Date) -> String {
        "\(state.appName) call, \(IslandAccessibility.spokenDuration(date.timeIntervalSince(state.startedAt)))"
    }
}
