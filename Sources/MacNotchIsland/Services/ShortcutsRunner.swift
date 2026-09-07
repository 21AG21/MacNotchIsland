import Foundation
import Combine

/// Runs the user's Shortcuts from the island. (Stub: an implementation agent fills this in.)
final class ShortcutsRunner: ObservableObject {
    static let shared = ShortcutsRunner()
    @Published private(set) var available: [String] = []
    @Published var favorites: [String] = []

    private init() {}

    func refresh() {}
    func run(_ name: String) {}
}
