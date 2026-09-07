import SwiftUI

/// Top-level view inside each notch panel: the main island body centred over the notch,
/// plus the detached "minimal" bubble to its right when two activities are live.
struct IslandRootView: View {
    let geometry: NotchGeometry
    var panelID: String = "main"
    @EnvironmentObject private var center: ActivityCenter
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var menuBar = MenuBarClearance.shared
    @State private var previousLayout: IslandLayout? = nil

    var body: some View {
        let presentation = center.presentation(for: panelID)
        let layout = IslandLayout.make(presentation: presentation, geometry: geometry, center: center, clearance: menuBar.limits)
        let animation = IslandMotion.shape(from: previousLayout ?? layout, to: layout, direction: center.navigationDirection)

        ZStack(alignment: .top) {
            Color.clear
            if !center.isSuppressed {
            HStack(alignment: .top, spacing: layout.bubbleGap) {
                IslandBodyView(geometry: geometry, presentation: presentation, layout: layout, panelID: panelID)
                if layout.hasBubble, case .compact(_, let bubble) = presentation, let bubble {
                    BubbleView(activity: bubble, diameter: layout.bubbleDiameter)
                        .offset(y: layout.topInset)
                        .transition(IslandMotion.pop(scale: 0.2))
                }
            }
            // Keep the notch gap on the notch: undo the bubble's share of the row's width, and
            // shift the body by the difference between its two slots (see `bodyShift`).
            .offset(x: layout.bodyShift + (layout.hasBubble ? (layout.bubbleGap + layout.bubbleDiameter) / 2 : 0))
            // The bubble pops with its own, bouncier spring than the outline.
            .animation(IslandMotion.bubble, value: layout.hasBubble)
            .transition(.opacity)
            }
        }
        .animation(IslandMotion.quick, value: center.isSuppressed)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: layout)
        .onChange(of: layout, initial: true) { _, new in previousLayout = new }
    }
}
