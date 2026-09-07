import Combine
import CoreLocation
import Foundation

/// Current conditions for the Home panel's "Weather" tab.
///
/// No account, no API key and no third-party SDK: CoreLocation gives us an approximate
/// coordinate (kilometre accuracy is plenty for a weather panel), CLGeocoder turns it into
/// a town name, and Open-Meteo — free and keyless for non-commercial use — answers with the
/// current temperature, WMO condition code, wind and today's high/low.
///
/// Everything here runs on the main thread: the location manager is created there so its
/// delegate callbacks arrive there, and both the network and geocoder completions hop back
/// before touching a `@Published` property.
///
/// Cost control: `start()` / `stop()` are reference counted (the view calls them on appear
/// and disappear), a fetch is at most one HTTP request every 30 minutes, that interval is
/// stretched by `EnergyPolicy.shared.pollingMultiplier` on battery / Low Power Mode, and
/// nothing at all happens while the Mac is asleep. The last reading is cached in
/// UserDefaults so the tab shows something the instant it opens.
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    /// What the tab should be showing.
    enum State: Equatable {
        /// Nothing asked for weather yet.
        case idle
        /// Waiting on CoreLocation (permission prompt or a first fix).
        case locating
        /// Have a coordinate, waiting on Open-Meteo.
        case loading
        /// `temperatureC` and friends are worth showing.
        case ready
        /// Location access was refused (or a profile forbids it).
        case denied
        /// The request failed and there is nothing to fall back on.
        case failed
    }

    /// One reading, in the units Open-Meteo answers in (Celsius, km/h). This is also the
    /// shape cached in UserDefaults, so a relaunch starts with the last known weather
    /// instead of an empty panel.
    struct Snapshot: Codable, Equatable {
        var temperatureC: Double
        /// WMO weather interpretation code — see `condition(code:isDay:)`.
        var weatherCode: Int
        var windKmh: Double
        var isDay: Bool
        var highC: Double?
        var lowC: Double?
        var placeName: String?
        var updatedAt: Date

        init(temperatureC: Double,
             weatherCode: Int,
             windKmh: Double,
             isDay: Bool,
             highC: Double? = nil,
             lowC: Double? = nil,
             placeName: String? = nil,
             updatedAt: Date = Date()) {
            self.temperatureC = temperatureC
            self.weatherCode = weatherCode
            self.windKmh = windKmh
            self.isDay = isDay
            self.highC = highC
            self.lowC = lowC
            self.placeName = placeName
            self.updatedAt = updatedAt
        }
    }

    // MARK: - Published state

    @Published private(set) var state: State = .idle
    @Published private(set) var temperatureC: Double? = nil
    @Published private(set) var highC: Double? = nil
    @Published private(set) var lowC: Double? = nil
    @Published private(set) var windKmh: Double? = nil
    @Published private(set) var isDay: Bool = true
    @Published private(set) var conditionSymbol: String = "cloud"
    @Published private(set) var conditionText: String = ""
    @Published private(set) var placeName: String? = nil
    @Published private(set) var updatedAt: Date? = nil

    // MARK: - Configuration

    /// The floor on how often we are willing to hit the network while started.
    static let refreshInterval: TimeInterval = 30 * 60
    private static let requestTimeout: TimeInterval = 12
    private static let cacheKey = "weatherSnapshot"
    private static let userAgent = "NotchIsland/1.0 (https://github.com/21AG21/MacNotchIsland)"
    /// Don't re-run the geocoder for a coordinate that has barely moved.
    private static let geocodeDistanceThreshold: CLLocationDistance = 5_000

    // MARK: - Private state (main thread only)

    private var manager: CLLocationManager?
    private let geocoder = CLGeocoder()
    private var subscribers = 0
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var energyCancellable: AnyCancellable?
    private var task: URLSessionDataTask?
    private var snapshot: Snapshot?
    private var lastCoordinate: CLLocationCoordinate2D?
    private var geocodedCoordinate: CLLocationCoordinate2D?
    private var lastPlaceName: String?
    private var locationRequestInFlight = false

    private override init() {
        super.init()
        applyCachedSnapshot()
    }

    // MARK: - Reference-counted lifetime

    /// Claim the weather. Balanced by `stop()`; only the first caller starts the timer, and
    /// a cached reading younger than `refreshInterval` is reused rather than re-fetched.
    func start() {
        subscribers += 1
        guard subscribers == 1 else { return }

        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rescheduleTimer() }
        rescheduleTimer()

        if isStale { refresh() }
    }

    /// Release a claim. Once the last view goes away nothing is left running.
    func stop() {
        guard subscribers > 0 else { return }
        subscribers -= 1
        guard subscribers == 0 else { return }

        timer?.invalidate()
        timer = nil
        timerInterval = 0
        energyCancellable?.cancel()
        energyCancellable = nil
        task?.cancel()
        task = nil
        geocoder.cancelGeocode()
        locationRequestInFlight = false
        // A spinner that nobody is watching should not be what greets the next viewer.
        if state == .locating || state == .loading {
            state = snapshot == nil ? .idle : .ready
        }
    }

    /// Fetch now: the timer, the Retry button and the first `start()` all come through here.
    /// Re-asks CoreLocation for a fix, which is also how the place name stays current.
    func refresh() {
        guard !EnergyPolicy.shared.isAsleep else { return }
        ensureManager()
        resolveAuthorization()
    }

    /// True while at least one view is on screen asking for weather.
    private var isRunning: Bool { subscribers > 0 }

    /// True when the cached reading is old enough (or missing) to be worth a request.
    private var isStale: Bool {
        guard let updatedAt = updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) >= Self.refreshInterval
    }

    // MARK: - Timer

    private var interval: TimeInterval {
        Self.refreshInterval * max(1, EnergyPolicy.shared.pollingMultiplier)
    }

    /// Rebuilds the timer whenever the energy policy asks for a different cadence.
    private func rescheduleTimer() {
        guard isRunning else { return }
        let wanted = interval
        guard timer == nil || abs(wanted - timerInterval) > 0.01 else { return }
        timer?.invalidate()
        timerInterval = wanted
        let scheduled = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, !EnergyPolicy.shared.isAsleep else { return }
            self.refresh()
        }
        scheduled.tolerance = wanted * 0.2
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
    }

    // MARK: - CoreLocation

    /// The manager is created lazily (and on the main thread, so its delegate callbacks
    /// land there) — an app whose owner never opens the Weather tab never touches
    /// CoreLocation at all, and so never sees a permission prompt.
    private func ensureManager() {
        guard manager == nil else { return }
        let created = CLLocationManager()
        created.delegate = self
        created.desiredAccuracy = kCLLocationAccuracyKilometer
        manager = created
    }

    private func resolveAuthorization() {
        guard let manager = manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            beginLocating()
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            // `.authorized` is the deprecated spelling of `.authorizedAlways`; they are the
            // same value, so this arm covers it too.
            requestLocation()
        case .denied, .restricted:
            state = .denied
        @unknown default:
            if snapshot == nil { state = .failed }
        }
    }

    private func requestLocation() {
        guard let manager = manager, !locationRequestInFlight else { return }
        locationRequestInFlight = true
        beginLocating()
        // One-shot: CoreLocation delivers a single fix and stops, so nothing keeps the
        // location machinery (or the menu-bar arrow) alive between refreshes.
        manager.requestLocation()
    }

    /// Only show the spinner when there is nothing better on screen; a background refresh
    /// over an existing reading should be invisible.
    private func beginLocating() {
        if snapshot == nil { state = .locating }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocation()
        case .denied, .restricted:
            state = .denied
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locationRequestInFlight = false
        guard isRunning else { return }   // the tab closed while the fix was in flight
        guard let location = locations.last else { return }
        lastCoordinate = location.coordinate
        reverseGeocodeIfNeeded(location)
        fetchWeather(for: location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationRequestInFlight = false
        guard isRunning else { return }
        NSLog("Notch Island: location request failed (\(error.localizedDescription)).")
        if let coordinate = lastCoordinate {
            // A fix from earlier in the session beats no weather at all.
            fetchWeather(for: coordinate)
        } else if snapshot == nil {
            state = .failed
        }
    }

    /// Best effort: a town name is a nicety, so a geocoder failure is simply ignored and
    /// the corner of the panel stays blank.
    private func reverseGeocodeIfNeeded(_ location: CLLocation) {
        if lastPlaceName != nil, let previous = geocodedCoordinate {
            let previousLocation = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            if previousLocation.distance(from: location) < Self.geocodeDistanceThreshold { return }
        }
        geocoder.cancelGeocode()
        let coordinate = location.coordinate
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            let placemark = placemarks?.first
            let resolved = placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.administrativeArea
            guard let self, let name = resolved, !name.isEmpty else { return }
            DispatchQueue.main.async {
                // Only a successful lookup counts as "geocoded here"; a failed one must retry next time.
                self.geocodedCoordinate = coordinate
                self.applyPlaceName(name)
            }
        }
    }

    private func applyPlaceName(_ name: String) {
        lastPlaceName = name
        // Fold it into the reading on screen when there is one, so the cache keeps it too.
        if var updated = snapshot {
            updated.placeName = name
            apply(updated)
        } else {
            placeName = name
        }
    }

    // MARK: - Open-Meteo

    /// The forecast endpoint for a coordinate. Rounded to three decimals (~100 m) — the
    /// panel cannot tell the difference and there is no reason to put a precise home
    /// address in a query string.
    static func forecastURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        let lat = (latitude * 1000).rounded() / 1000
        let lon = (longitude * 1000).rounded() / 1000
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: "\(lat)"),
            URLQueryItem(name: "longitude", value: "\(lon)"),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        return components?.url
    }

    private func fetchWeather(for coordinate: CLLocationCoordinate2D) {
        guard !EnergyPolicy.shared.isAsleep else { return }
        guard let url = Self.forecastURL(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            if snapshot == nil { state = .failed }
            return
        }
        if snapshot == nil { state = .loading }
        task?.cancel()
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let dataTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handle(data: data, response: response, error: error)
            }
        }
        task = dataTask
        dataTask.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?) {
        task = nil
        // `stop()` cancels in-flight work; that is not a failure worth reporting.
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard error == nil, (200..<300).contains(status), let data, var fresh = Self.parse(data) else {
            let reason = error?.localizedDescription ?? "HTTP \(status)"
            NSLog("Notch Island: weather fetch failed (\(reason)).")
            // A stale reading still beats an error message, so only give up when the panel
            // has nothing at all to show.
            if snapshot == nil { state = .failed }
            return
        }
        fresh.placeName = lastPlaceName ?? placeName
        apply(fresh)
    }

    /// Decodes one Open-Meteo forecast response. Nil for anything that isn't the shape we
    /// asked for; the daily block and the optional current fields may simply be missing.
    static func parse(_ data: Data) -> Snapshot? {
        guard let decoded = try? JSONDecoder().decode(Forecast.self, from: data) else { return nil }
        let current = decoded.current
        return Snapshot(temperatureC: current.temperature,
                        weatherCode: current.weatherCode,
                        windKmh: current.windSpeed ?? 0,
                        isDay: (current.isDay ?? 1) != 0,
                        highC: decoded.daily?.maxTemperature?.first,
                        lowC: decoded.daily?.minTemperature?.first)
    }

    /// Just the fields the panel needs out of an Open-Meteo forecast payload.
    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature: Double
            let weatherCode: Int
            let windSpeed: Double?
            let isDay: Int?

            enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m"
                case weatherCode = "weather_code"
                case windSpeed = "wind_speed_10m"
                case isDay = "is_day"
            }
        }

        struct Daily: Decodable {
            let maxTemperature: [Double]?
            let minTemperature: [Double]?

            enum CodingKeys: String, CodingKey {
                case maxTemperature = "temperature_2m_max"
                case minTemperature = "temperature_2m_min"
            }
        }

        let current: Current
        let daily: Daily?
    }

    // MARK: - Publishing & cache

    private func apply(_ fresh: Snapshot, cache: Bool = true) {
        snapshot = fresh
        temperatureC = fresh.temperatureC
        highC = fresh.highC
        lowC = fresh.lowC
        windKmh = fresh.windKmh
        isDay = fresh.isDay
        let condition = Self.condition(code: fresh.weatherCode, isDay: fresh.isDay)
        conditionSymbol = condition.symbol
        conditionText = condition.text
        placeName = fresh.placeName
        lastPlaceName = fresh.placeName ?? lastPlaceName
        updatedAt = fresh.updatedAt
        state = .ready
        if cache { writeCache(fresh) }
    }

    private func applyCachedSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        apply(cached, cache: false)
    }

    private func writeCache(_ fresh: Snapshot) {
        guard let data = try? JSONEncoder().encode(fresh) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    // MARK: - Formatting (pure, unit-tested)

    /// True when this Mac's locale wants Celsius and km/h.
    static var usesMetric: Bool {
        Locale.current.measurementSystem == .metric
    }

    /// WMO weather interpretation code → an SF Symbol and a short label. Night codes get
    /// the moon variants where one exists. Anything unrecognised falls back to plain cloud.
    static func condition(code: Int, isDay: Bool) -> (symbol: String, text: String) {
        switch code {
        case 0:
            return (isDay ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1, 2:
            return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3:
            return ("cloud.fill", "Overcast")
        case 45, 48:
            return ("cloud.fog.fill", "Fog")
        case 51...57:
            return ("cloud.drizzle.fill", "Drizzle")
        case 61...67, 80...82:
            return ("cloud.rain.fill", "Rain")
        case 71...77, 85...86:
            return ("cloud.snow.fill", "Snow")
        case 95...99:
            return ("cloud.bolt.rain.fill", "Thunderstorm")
        default:
            return ("cloud.fill", "Cloudy")
        }
    }

    /// "21°" — whole degrees in the reader's scale. The scale is chosen by the caller
    /// (`usesMetric`) rather than spelled out, the way every weather widget shows it.
    static func formatTemperature(_ celsius: Double, usesMetric: Bool) -> String {
        let value = usesMetric ? celsius : celsius * 9 / 5 + 32
        let rounded = Int(value.rounded())
        return "\(rounded)°"
    }

    /// "12 km/h" or "8 mph", whole units.
    static func formatWind(_ kmh: Double, usesMetric: Bool) -> String {
        if usesMetric {
            return "\(Int(kmh.rounded())) km/h"
        }
        return "\(Int((kmh * 0.621371).rounded())) mph"
    }
}
