import Foundation
import Combine

/// Current conditions for the Home panel. (Stub: an implementation agent fills this in
/// with CoreLocation + Open-Meteo.)
final class WeatherService: ObservableObject {
    static let shared = WeatherService()
    @Published private(set) var temperatureC: Double? = nil
    @Published private(set) var conditionSymbol: String = "cloud"
    @Published private(set) var conditionText: String = ""

    private init() {}

    func refresh() {}
    func start() {}
    func stop() {}
}
