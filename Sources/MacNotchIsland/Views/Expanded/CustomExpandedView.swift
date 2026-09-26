import AppKit
import SwiftUI

/// Expanded view for third-party Live Activities pushed through the URL scheme / notchctl.
struct CustomExpandedView: View {
    let state: CustomActivity
    let activity: IslandActivity
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel
    /// Observed for "Let pushed cards run Shortcuts", so a button that runs one greys out the
    /// moment the switch is turned off, rather than at the next push.
    @ObservedObject private var prefs = Preferences.shared

    private var tint: Color { Color.named(state.tint) }

    /// A web link, or a Shortcut by name — or, on one of the island's own cards, something the
    /// app does itself. The panel goes first either way: whatever happens next happens in
    /// another app, and the island has no business sitting over it. What the press does is
    /// decided now, with the switch as it is now (`LiveActivityAPI.press`).
    static func perform(_ action: CustomAction, activityID: String) {
        let press = LiveActivityAPI.press(action, activityID: activityID,
                                          allowsShortcuts: Preferences.shared.apiShortcutsEnabled)
        switch press {
        case .command(let command):
            ActivityCenter.shared.collapse(reason: "a scripted action")
            command.perform()
        case .link(let url):
            ActivityCenter.shared.collapse(reason: "a scripted action")
            NSWorkspace.shared.open(url)
        case .shortcut(let name):
            ActivityCenter.shared.collapse(reason: "a scripted action")
            ShortcutsRunner.shared.run(name)
        case .refused:
            // The button is greyed out for this; a press that gets here anyway runs nothing.
            IslandLog.island.notice("a pushed card's Shortcut was not run: Let pushed cards run Shortcuts is off")
        case .nothing:
            break
        }
    }

    /// Whether a button does anything if pressed now. One that would not is drawn disabled.
    private func isLive(_ action: CustomAction) -> Bool {
        switch LiveActivityAPI.press(action, activityID: activity.id, allowsShortcuts: prefs.apiShortcutsEnabled) {
        case .refused, .nothing: return false
        case .command, .link, .shortcut: return true
        }
    }

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
                if let since = state.countsUpFrom {
                    // The call card's clock: the same face, the same one-second beat.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(ctx.date.timeIntervalSince(since).mmss)
                            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: false))
                            .lineLimit(1)
                            // Said from inside the timeline, the way the call's card says its
                            // time, so it is the time now. It was said in the card's summary,
                            // worked out when the card's body last ran — which a ticking clock
                            // does not make it do — and VoiceOver read a time minutes old.
                            .accessibilityLabel(IslandAccessibility.spokenDuration(ctx.date.timeIntervalSince(since)))
                    }
                } else if let text = state.trailingText {
                    Text(text)
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                // The buttons a script asked for, named rather than glyphed: a script's action
                // is "Retry" or "Open the logs", and a disc with an arrow on it says neither.
                ForEach(Array(state.actions.prefix(LiveActivityAPI.maxActions).enumerated()), id: \.offset) { pair in
                    let live = isLive(pair.element)
                    PillButton(title: pair.element.title, symbol: pair.element.symbol,
                               tint: tint, prominent: pair.offset == 0) {
                        Self.perform(pair.element, activityID: activity.id)
                    }
                    // At the size a row's controls are, so two of them and the title always
                    // fit across a card that is 440 points wide.
                    .environment(\.islandCompactControls, true)
                    // A Shortcut the switch no longer allows: still there, so the card reads as
                    // it did, and greyed out, since the island's button style does not dim a
                    // disabled one by itself.
                    .disabled(!live)
                    .opacity(live ? 1 : 0.4)
                }
                if state.url != nil, state.actions.isEmpty {
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
    /// sentence; the Open button (when there is a URL) stays reachable underneath. A running
    /// clock is not in it: the clock says its own time, from the timeline that draws it.
    private var accessibilitySummary: String {
        var parts = [state.title]
        if let subtitle = state.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if let body = state.body, !body.isEmpty { parts.append(body) }
        if state.countsUpFrom == nil, let text = state.trailingText {
            parts.append(text)
        }
        return parts.joined(separator: ", ")
    }
}
