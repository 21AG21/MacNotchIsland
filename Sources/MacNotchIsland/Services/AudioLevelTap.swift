import Foundation
import Combine

/// System audio level for the reactive visualizer. (Stub: an implementation agent fills
/// this in with a Core Audio process tap; requires macOS 14.2 and audio-capture consent.)
final class AudioLevelTap: ObservableObject {
    static let shared = AudioLevelTap()
    /// 0…1, smoothed, published at most ~20 Hz while running.
    @Published private(set) var level: Double = 0
    @Published private(set) var isRunning = false

    private init() {}

    func start() {}
    func stop() {}
}
