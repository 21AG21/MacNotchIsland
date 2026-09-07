import SwiftUI

/// Top-level view inside each notch panel: the main island body centred over the notch,
/// plus the detached "minimal" bubble to its right when two activities are live.
struct IslandRootView: View {
    let geometry: NotchGeometry
    var panelID: String = "main"
    @EnvironmentObject private var center: ActivityCenter
    @EnvironmentObject private var prefs: Preferences
    @State private var previousLayout: IslandLayout? = nil

    var body: some View {
        let presentation = center.presentation(for: panelID)
        let layout = IslandLayout.make(presentation: presentation, geometry: geometry, center: center)
        let animation = IslandMotion.shape(from: previousLayout ?? layout, to: layout)

        ZStack(alignment: .top) {
            Color.clear
            HStack(alignment: .top, spacing: layout.bubbleGap) {
                IslandBodyView(geometry: geometry, presentation: presentation, layout: layout, panelID: panelID)
                if layout.hasBubble, case .compact(_, let bubble) = presentation, let bubble {
                    BubbleView(activity: bubble, diameter: layout.bubbleDiameter)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            // Keep the main body centred on the notch when the bubble is present.
            .offset(x: layout.hasBubble ? (layout.bubbleGap + layout.bubbleDiameter) / 2 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: layout)
        .onChange(of: layout, initial: true) { _, new in previousLayout = new }
    }
}
