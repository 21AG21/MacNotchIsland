import Foundation
import Combine

/// Daily check of the GitHub releases page. (Stub: an implementation agent fills this in.)
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var latestVersion: String? = nil
    @Published private(set) var updateAvailable = false

    private init() {}

    func start() {}
    func stop() {}
    func checkNow() {}
}
