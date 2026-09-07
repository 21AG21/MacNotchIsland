import SwiftUI

/// Joins a view to the island's shared matched-geometry group, when there is one.
///
/// Compact and expanded content are two different views swapped by `.id(presentation.contentID)`
/// plus a `.blurReplace` transition, so a "hero" element (artwork, digits, the visualizer) only
/// morphs if both sides sit in the *same* `Namespace.ID` under the *same* id. `IslandBodyView`
/// publishes that namespace through `\.islandNamespace`; anything rendered outside the island
/// (previews, the settings window, a stray unit test host) gets `nil` and simply renders plainly.
private struct IslandMatchedModifier: ViewModifier {
    let id: String
    @Environment(\.islandNamespace) private var namespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            // `isSource` stays default on both sides: whichever copy SwiftUI keeps as the source
            // during the swap, the other one animates from the group's previous frame, which is
            // what makes the small artwork grow into the large one (and shrink back).
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// Morph this view into its counterpart on the other side of a compact ↔ expanded swap.
    ///
    /// Apply it to a container whose identity is stable across the swap (e.g. the whole
    /// `ArtworkView`, not the `Image` inside a branch that comes and goes).
    func islandMatched(_ id: String) -> some View {
        modifier(IslandMatchedModifier(id: id))
    }
}

/// Well-known matched-geometry ids, so the two sides can never drift apart.
enum IslandMatchedID {
    static let nowPlayingArtwork = "np.artwork"
    static let nowPlayingVisualizer = "np.visualizer"
    static let timerTime = "timer.time"
    static let stopwatchTime = "stopwatch.time"
    static let callGlyph = "call.glyph"
    static let callTime = "call.time"
}
