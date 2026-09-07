import SwiftUI

/// Shared matched-geometry namespace so compact content (artwork, timer digits) can morph
/// into its expanded counterpart the way the iPhone's island does.
private struct IslandNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var islandNamespace: Namespace.ID? {
        get { self[IslandNamespaceKey.self] }
        set { self[IslandNamespaceKey.self] = newValue }
    }
}
