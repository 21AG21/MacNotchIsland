import Foundation
import Combine

/// Time-synced lyrics for the current track. (Stub: an implementation agent fills this in.)
final class LyricsService: ObservableObject {
    static let shared = LyricsService()
    @Published private(set) var currentLine: String? = nil

    private init() {}

    func start() {}
    func stop() {}
}
