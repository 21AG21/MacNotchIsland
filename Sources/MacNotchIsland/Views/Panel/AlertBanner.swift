import SwiftUI

/// An alert that arrives while the panel is showing takes the control rail's row for a
/// moment: the glyph, a title, the value the pill would show. The panel's content stays
/// exactly where it is, and a click opens the alert's card.
struct AlertBanner: View {
    let activity: IslandActivity
    @EnvironmentObject private var center: ActivityCenter

    var body: some View {
        Button(action: act) {
            HStack(spacing: 10) {
                CompactLeadingView(activity: activity, height: 28)
                    .frame(width: 28, height: 28)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                CompactTrailingView(activity: activity, height: 28)
                    .frame(width: 90, height: 28)
            }
            .padding(.horizontal, 12)
            .frame(width: IslandLayout.panelContentWidth, height: 32)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(IslandButtonStyle())
        .frame(height: IslandLayout.railHeight)
        .accessibilityLabel(IslandAccessibility.compactLabel(for: activity.content))
    }

    private var title: String {
        switch activity.content {
        case .battery(let b): return b.title
        case .bluetooth(let d): return d.isConnected ? "\(d.name) connected" : "\(d.name) disconnected"
        case .focus(let f): return f.isOn ? "\(f.name) on" : "\(f.name) off"
        case .download(let d): return d.isComplete ? "\(d.name) downloaded" : "Downloading \(d.name)"
        case .calendar(let c): return c.title
        case .custom(let c): return c.title
        case .call(let c): return "Call in \(c.appName)"
        case .timer(let t): return t.isFinished ? "\(t.label) done" : t.label
        case .unlock: return "Unlocked"
        case .silent(let s): return s.isSilent ? "Silent" : "Sound on"
        case .hud(let h): return h.isMuted ? "Muted" : h.title
        default: return IslandAccessibility.compactLabel(for: activity.content)
        }
    }

    private func act() {
        if case .hud = activity.content {
            center.dismissAlert()
        } else if activity.content.hasExpandedView {
            center.open(ActivityCenter.view(for: activity))
        } else if let action = activity.openAction {
            action.perform()
            center.dismissAlert()
        } else {
            center.dismissAlert()
        }
    }
}
