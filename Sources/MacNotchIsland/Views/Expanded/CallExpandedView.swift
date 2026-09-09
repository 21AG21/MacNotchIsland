import SwiftUI

struct CallExpandedView: View {
    let state: CallState
    let activity: IslandActivity
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    private var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: state.bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                // One stable container for both branches, so the matched group keeps its member
                // whether or not the app icon resolves.
                ZStack {
                    if let icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Circle().fill(Color.named("green").opacity(0.18))
                        Image(systemName: "phone.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.named("green"))
                    }
                }
                .frame(width: 44, height: 44)
                .islandMatched(IslandMatchedID.callGlyph)
                .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.appName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Call in progress")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(ctx.date.timeIntervalSince(state.startedAt).mmss)
                            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: false))
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .islandMatched(IslandMatchedID.callTime)
                    }
                    // Name, status and the ticking digits read as one sentence; the button
                    // beside them keeps its own label.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenLabel(at: ctx.date))
                }
                // Nothing public can hang up another app's call, so this jumps to the app that
                // owns it, in the call's own green rather than a hang-up red that would lie.
                CircleActionButton(symbol: "phone.fill", tint: Color.named("green"),
                                   filled: true, glyph: .white,
                                   label: "Go to call in \(state.appName)") {
                    goToCall()
                }
            }
            .islandContentColumn()
            .padding(.bottom, insidePanel ? 0 : 16)
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }

    private func goToCall() {
        if let open = activity.openAction {
            open.perform()
        } else {
            OpenAction.app(bundleID: state.bundleID).perform()
        }
    }

    /// "FaceTime call, 4 minutes 12 seconds".
    private func spokenLabel(at date: Date) -> String {
        "\(state.appName) call, \(IslandAccessibility.spokenDuration(date.timeIntervalSince(state.startedAt)))"
    }
}
