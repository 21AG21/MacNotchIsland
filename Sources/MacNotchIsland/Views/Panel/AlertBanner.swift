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
                // Hung from the banner's padding, as the figure at the far end is: the pill's
                // notch-side padding has no cutout to keep clear of here.
                CompactLeadingView(activity: activity, height: 28, besideNotch: false)
                    .frame(width: 28, height: 28)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if case .hud(let hud) = activity.content {
                    // The level gets the room a banner has: a long bar and the figure. An
                    // output that carries its own level has no bar to draw — an empty one
                    // there reads as a Mac turned all the way down, which is the opposite.
                    if hud.isUnavailable {
                        // The output is named in the title; this says what to do about it.
                        Text(LevelHUD.unavailableHint(hud))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    } else {
                        LevelBar(level: hud.isMuted ? 0 : hud.level, tint: .white)
                            .frame(width: 140, height: 4)
                    }
                    Text(LevelHUD.readout(hud))
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 44, alignment: .trailing)
                } else {
                    CompactTrailingView(activity: activity, height: 28)
                        .frame(width: 90, height: 28)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: IslandLayout.panelContentWidth, height: 32)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(IslandButtonStyle())
        .frame(height: IslandLayout.railHeight)
        // Out of the island's matched group. The banner borrows the pill's views, and the
        // pill's cover is a member of it (`IslandMatchedID.nowPlayingArtwork`): a track's sneak
        // peek up in the rail while the panel peeks on Now Playing put two sources with the
        // cover's id in the namespace at once, the 28 pt one here and the 60 pt one in the
        // section, and SwiftUI is free to swap their frames or jump between them. The banner
        // is not one end of a morph, so it joins none.
        .environment(\.islandNamespace, nil)
        .accessibilityLabel(IslandAccessibility.compactLabel(for: activity.content))
    }

    /// What the banner says beside the glyph. Pure, so the rule is tested.
    static func title(for activity: IslandActivity) -> String {
        switch activity.content {
        // A track's sneak peek: the title and the artist are already in the slot at the far
        // end, and the section under the banner may well be Now Playing showing that track.
        // The pill's spoken sentence stood here instead, and said the title a second time.
        case .nowPlaying where activity.id == NowPlayingService.peekAlertID: return Self.peekTitle
        case .battery(let b): return b.title
        case .bluetooth(let d): return d.isConnected ? "\(d.name) connected" : "\(d.name) disconnected"
        case .focus(let f): return f.isOn ? "\(f.name) on" : "\(f.name) off"
        case .download(let d): return d.isComplete ? "\(d.name) downloaded" : "Downloading \(d.name)"
        // The trailing slot already carries the free space, so a connected disk says the one
        // thing that slot cannot: that it has arrived.
        case .drive(let d): return d.event == .connected ? "\(d.name) connected" : "\(d.name) — \(d.subtitle)"
        case .capture(let c): return c.title
        case .calendar(let c): return c.title
        case .custom(let c): return c.title
        case .call(let c): return "Call in \(c.appName)"
        case .timer(let t): return t.isAlarm ? t.label : (t.isFinished ? "\(t.label) done" : t.label)
        case .unlock: return "Unlocked"
        case .silent(let s): return s.isSilent ? "Silent" : "Sound on"
        // Where the sound is going, whenever that is worth saying — it is the one thing the
        // system's bezel never tells you, and the reason this display is worth having. The
        // glyph beside it is already that device's, and the bar and the figure to the right
        // say the level, so the word "Volume" here would be the only thing in the row that
        // said nothing.
        case .hud(let h): return h.label
        default: return IslandAccessibility.compactLabel(for: activity.content)
        }
    }

    /// The sneak peek's own line: what just happened, which neither the slot beside it nor the
    /// section under it says.
    static let peekTitle = "New track"

    private var title: String { Self.title(for: activity) }

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
