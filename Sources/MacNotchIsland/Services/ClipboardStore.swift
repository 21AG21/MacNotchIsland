import AppKit
import Combine

/// Clipboard history. (Stub: an implementation agent fills this in.)
struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    var text: String
    var date: Date
}

final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    @Published private(set) var items: [ClipboardItem] = []

    private init() {}

    func start() {}
    func stop() {}
    func clear() { items.removeAll() }
}
