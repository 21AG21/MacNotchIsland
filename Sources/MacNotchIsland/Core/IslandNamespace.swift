import SwiftUI

/// Shared matched-geometry namespace so compact content (artwork, timer digits) can morph
/// into its expanded counterpart the way the iPhone's island does.
private struct IslandNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

/// Which island (which display's panel) a view is being drawn on. A control that acts on
/// "the open panel" — the switcher's close button, its slots — has to know whether the open
/// panel is this one: with an island on each of two displays, a panel pinned on one left
/// the other's peek showing a close button that closed the wrong panel.
private struct IslandPanelIDKey: EnvironmentKey {
    static let defaultValue: String = "main"
}

extension EnvironmentValues {
    var islandNamespace: Namespace.ID? {
        get { self[IslandNamespaceKey.self] }
        set { self[IslandNamespaceKey.self] = newValue }
    }

    var islandPanelID: String {
        get { self[IslandPanelIDKey.self] }
        set { self[IslandPanelIDKey.self] = newValue }
    }
}
