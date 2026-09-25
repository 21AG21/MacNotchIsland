import Combine
import CoreLocation
import Foundation

/// Current conditions for the Home panel's "Weather" tab.
///
/// No account, no API key and no third-party SDK: CoreLocation gives us an approximate
/// coordinate (kilometre accuracy is plenty for a weather panel), CLGeocoder turns it into
/// a town name, and Open-Meteo — free and keyless for non-commercial use — answers with the
/// current temperature, WMO condition code, today's high/low and the next few hours.
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

    /// One hour of the forecast: when, how warm, and what it is doing.
    struct Hour: Codable, Equatable, Identifiable {
        var date: Date
        var temperatureC: Double
        var weatherCode: Int
        var isDay: Bool
        var id: Date { date }
    }

    /// One reading, in the units Open-Meteo answers in (Celsius). This is also the shape
    /// cached in UserDefaults, so a relaunch starts with the last known weather instead of an
    /// empty panel. A reading cached by a build that still asked for the wind carries it too,
    /// and the decoder passes over it.
    struct Snapshot: Codable, Equatable {
        var temperatureC: Double
        /// WMO weather interpretation code — see `condition(code:isDay:)`.
        var weatherCode: Int
        var isDay: Bool
        var highC: Double?
        var lowC: Double?
        var placeName: String?
        var updatedAt: Date
        /// The next few hours, when the forecast carried them.
        var hours: [Hour] = []

        init(temperatureC: Double,
             weatherCode: Int,
             isDay: Bool,
             highC: Double? = nil,
             lowC: Double? = nil,
             placeName: String? = nil,
             updatedAt: Date = Date(),
             hours: [Hour] = []) {
            self.temperatureC = temperatureC
            self.weatherCode = weatherCode
            self.isDay = isDay
            self.highC = highC
            self.lowC = lowC
            self.placeName = placeName
            self.updatedAt = updatedAt
            self.hours = hours
        }
    }

    // MARK: - Published state

    @Published private(set) var state: State = .idle
    @Published private(set) var temperatureC: Double? = nil
    @Published private(set) var highC: Double? = nil
    @Published private(set) var lowC: Double? = nil
    @Published private(set) var isDay: Bool = true
    @Published private(set) var conditionSymbol: String = "cloud"
    @Published private(set) var conditionText: String = ""
    @Published private(set) var placeName: String? = nil
    @Published private(set) var updatedAt: Date? = nil
    /// The next few hours, for the strip in Today. Empty until a forecast carrying them lands.
    @Published private(set) var hours: [Hour] = []

    /// The hours still to come, which is what the strip shows. `hours` is kept as it was
    /// fetched — and as it was cached, which is how a morning relaunch with no network put
    /// last night's evening up as the next six hours.
    var upcomingHours: [Hour] { Self.upcoming(hours) }

    static func upcoming(_ hours: [Hour], after now: Date = Date()) -> [Hour] {
        hours.filter { $0.date > now }
    }

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
    /// How many of those may ask for Location: a panel somebody pinned open. A peek is a
    /// viewer too, and reads whatever has been granted without asking, see `locationStep`.
    private var askers = 0
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

    /// Claim the weather. Balanced by `stop(mayAsk:)` with the same flag; only the first caller
    /// starts the timer, and a cached reading younger than `refreshInterval` is reused rather
    /// than re-fetched.
    ///
    /// `mayAsk` is whether this viewer may put macOS's Location question on screen. Any Today
    /// on screen used to start the weather, and its first refresh asked — so a pointer resting
    /// on the notch, a peek landing on Today, put the Location sheet up. The same rule as the
    /// agenda's (`AgendaStore.Hold`): a peek reads what has been granted, a panel somebody
    /// pinned open may ask.
    func start(mayAsk: Bool = false) {
        subscribers += 1
        if mayAsk { askers += 1 }
        if subscribers == 1 {
            energyCancellable = EnergyPolicy.shared.objectWillChange
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.rescheduleTimer() }
            rescheduleTimer()
            if isStale { refresh() }
        } else if mayAsk, askers == 1, locationUnasked() {
            // The first viewer that may ask, joining ones that could not: a peek pinned open.
            // A question never put is put now, not at the next refresh half an hour on.
            refresh()
        }
    }

    /// Moves one viewer's claim from `old` to `new`. The new claim is taken before the old one
    /// is given back, so a peek pinned open stays one viewer throughout and its timer and any
    /// fetch in flight carry on.
    func move(from old: AgendaStore.Hold, to new: AgendaStore.Hold) {
        guard old != new else { return }
        if new != .off { start(mayAsk: new == .asking) }
        if old != .off { stop(mayAsk: old == .asking) }
    }

    /// Release a claim, with the flag it was taken with. Once the last view goes away nothing
    /// is left running.
    func stop(mayAsk: Bool = false) {
        guard subscribers > 0 else { return }
        if mayAsk, askers > 0 { askers -= 1 }
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
    /// Re-asks CoreLocation for a fix, which is also how the place name stays current. Asks
    /// for Location only while a viewer that may ask holds the weather (`start(mayAsk:)`).
    func refresh() {
        guard !EnergyPolicy.shared.isAsleep else { return }
        ensureManager()
        resolveAuthorization(mayAsk: askers > 0)
    }

    /// Whether Location has never been answered. Making the manager asks nothing.
    private func locationUnasked() -> Bool {
        ensureManager()
        return manager?.authorizationStatus == .notDetermined
    }

    /// True while at least one view is on screen asking for weather.
    private var isRunning: Bool { subscribers > 0 }

    /// True when the cached reading is old enough (or missing) to be worth a request. Either
    /// way from now: a reading stamped in the future is a clock that was set back, and it was
    /// never going to come due.
    private var isStale: Bool {
        guard let updatedAt = updatedAt else { return true }
        return abs(Date().timeIntervalSince(updatedAt)) >= Self.refreshInterval
    }

    // MARK: - How old a reading is

    /// What a reading is worth showing as, by its age.
    enum Age: Equatable {
        /// Young enough to be the weather.
        case current
        /// Old enough that it has to say so: "3 hrs ago", after the figure.
        case old(String)
        /// Too old to be shown at all.
        case expired
    }

    /// How many refreshes a reading may miss before it stops being the weather. One late
    /// answer is a slow network; three is a Mac that is offline, or has lost its location.
    static let missedRefreshes: Double = 3
    /// The age past which a reading is not shown, whatever it says: yesterday's temperature is
    /// not a fact about today.
    static let longestShown: TimeInterval = 24 * 3600

    /// How a reading taken at `updatedAt` should be shown at `now`, for a service refreshing
    /// every `interval` — which is stretched on battery, so the reading that is due in two
    /// hours in Low Power Mode is not called old after ninety minutes.
    ///
    /// The cache kept a reading of any age and the line showed it as the weather: after one
    /// good day, a Mac that went offline or refused its location said "18° · Clear" for good.
    ///
    /// Pure, so the ages can be tested without a clock.
    static func age(of updatedAt: Date?, interval: TimeInterval = WeatherService.refreshInterval,
                    at now: Date = Date()) -> Age {
        guard let updatedAt else { return .expired }
        // A reading from the future is a clock that was set back: how old it is cannot be
        // known, so it is taken as the distance either way.
        let seconds = abs(now.timeIntervalSince(updatedAt))
        if seconds < missedRefreshes * interval { return .current }
        guard seconds < longestShown else { return .expired }
        let hours = max(1, Int(seconds / 3600))
        return .old(hours == 1 ? "1 hr ago" : "\(hours) hrs ago")
    }

    /// The reading on screen, aged at `now` against the refresh the energy policy allows.
    func age(at now: Date = Date()) -> Age {
        Self.age(of: updatedAt, interval: interval, at: now)
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
    /// land there) — an app whose owner never opens Today, or who has the weather line
    /// switched off there, never touches
    /// CoreLocation at all, and so never sees a permission prompt.
    private func ensureManager() {
        guard manager == nil else { return }
        let created = CLLocationManager()
        created.delegate = self
        created.desiredAccuracy = kCLLocationAccuracyKilometer
        manager = created
    }

    /// What a refresh does with Location as it stands, for a viewer that may or may not ask.
    enum LocationStep: Equatable {
        /// Put macOS's question on screen.
        case ask
        /// Granted: ask for a fix.
        case locate
        /// Refused, or not ours to have.
        case refuse
        /// Never answered, and this viewer may not ask: nothing is asked and nothing changes,
        /// and the line shows whatever it was showing.
        case wait
        case unknown
    }

    /// Pure, so the rule is tested: a question only where one may be asked, and everything
    /// already answered read the same either way.
    static func locationStep(_ status: CLAuthorizationStatus, mayAsk: Bool) -> LocationStep {
        switch status {
        case .notDetermined:
            return mayAsk ? .ask : .wait
        case .authorizedAlways, .authorizedWhenInUse:
            // `.authorized` is the deprecated spelling of `.authorizedAlways`; they are the
            // same value, so this arm covers it too.
            return .locate
        case .denied, .restricted:
            return .refuse
        @unknown default:
            return .unknown
        }
    }

    private func resolveAuthorization(mayAsk: Bool) {
        guard let manager = manager else { return }
        switch Self.locationStep(manager.authorizationStatus, mayAsk: mayAsk) {
        case .ask:
            beginLocating()
            manager.requestWhenInUseAuthorization()
        case .locate:
            requestLocation()
        case .refuse:
            refused()
        case .wait:
            break
        case .unknown:
            if snapshot == nil { state = .failed }
        }
    }

    /// Location was refused. The reading on screen goes with it, and the cached one: there is
    /// no next one coming to replace it, and kept, it stood in for the weather at every launch
    /// and hid the "Allow Location" offer that is the only way to get the weather back.
    private func refused() {
        state = .denied
        guard snapshot != nil || updatedAt != nil else { return }
        snapshot = nil
        temperatureC = nil
        highC = nil
        lowC = nil
        isDay = true
        conditionSymbol = "cloud"
        conditionText = ""
        updatedAt = nil
        hours = []
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
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
            refused()
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
        IslandLog.network.error("location request failed: \(error.localizedDescription, privacy: .public)")
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
            // Only what is drawn. The wind was asked for, decoded and cached, and shown
            // nowhere at all.
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "timezone", value: "auto"),
            // Two days, because "the next six hours" at nine in the evening is tomorrow.
            URLQueryItem(name: "forecast_days", value: "2"),
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
            IslandLog.network.error("weather fetch failed: \(reason, privacy: .public)")
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
                        isDay: (current.isDay ?? 1) != 0,
                        highC: decoded.daily?.maxTemperature?.first,
                        lowC: decoded.daily?.minTemperature?.first,
                        hours: hours(from: decoded.hourly))
    }

    /// How many hours ahead the strip shows.
    static let hoursAhead = 6

    /// The next few hours out of an hourly block, starting with the one after this one.
    ///
    /// Open-Meteo returns local wall-clock times with no zone on them, because the request
    /// asked for `timezone=auto` — so they are read in the machine's own zone, which is the
    /// one the forecast was made for.
    ///
    /// Pure, so the arithmetic can be tested without the network.
    static func hours(from block: Forecast.Hourly?, now: Date = Date(),
                      calendar: Calendar = .current) -> [Hour] {
        guard let block, let times = block.time else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        // The three arrays are parallel, and a short one is a malformed answer rather than a
        // reason to read off the end of it.
        func value<T>(_ array: [T]?, _ index: Int) -> T? {
            guard let array, index >= 0, index < array.count else { return nil }
            return array[index]
        }
        var out: [Hour] = []
        for (index, raw) in times.enumerated() {
            guard let date = formatter.date(from: raw), date > now else { continue }
            guard let temperature = value(block.temperature, index) else { continue }
            out.append(Hour(date: date,
                            temperatureC: temperature,
                            weatherCode: value(block.weatherCode, index) ?? 0,
                            isDay: (value(block.isDay, index) ?? 1) != 0))
            if out.count == hoursAhead { break }
        }
        return out
    }

    /// Just the fields the panel needs out of an Open-Meteo forecast payload.
    struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature: Double
            let weatherCode: Int
            let isDay: Int?

            enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m"
                case weatherCode = "weather_code"
                case isDay = "is_day"
            }
        }

        struct Hourly: Decodable {
            let time: [String]?
            let temperature: [Double]?
            let weatherCode: [Int]?
            let isDay: [Int]?

            enum CodingKeys: String, CodingKey {
                case time
                case temperature = "temperature_2m"
                case weatherCode = "weather_code"
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
        let hourly: Hourly?
    }

    /// Fills in a reading for the gallery, which has no network and no location.
    func seedForGallery(_ snapshot: Snapshot) {
        apply(snapshot, cache: false)
    }

    // MARK: - Publishing & cache

    private func apply(_ fresh: Snapshot, cache: Bool = true) {
        snapshot = fresh
        temperatureC = fresh.temperatureC
        highC = fresh.highC
        lowC = fresh.lowC
        isDay = fresh.isDay
        let condition = Self.condition(code: fresh.weatherCode, isDay: fresh.isDay)
        conditionSymbol = condition.symbol
        conditionText = condition.text
        placeName = fresh.placeName
        lastPlaceName = fresh.placeName ?? lastPlaceName
        updatedAt = fresh.updatedAt
        hours = fresh.hours
        state = .ready
        if cache { writeCache(fresh) }
    }

    /// The last reading, put up at launch so Today has something to show the instant it
    /// opens. Nothing on screen takes it at its word: the line ages it (`age(at:)`) before
    /// showing it, so a reading from last week is not what greets somebody offline.
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

    /// Whether this Mac's reader wants Fahrenheit.
    ///
    /// `Locale.MeasurementSystem` has three cases and only one of them is `.metric`: the
    /// United Kingdom is its own, and it takes its temperature in Celsius. Asking `!= .metric`
    /// would put Fahrenheit in front of every reader in Britain.
    static var usesFahrenheit: Bool { Locale.current.measurementSystem == .us }

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

    /// "21°" — whole degrees in the reader's scale, which the caller names rather than the
    /// number spelling it out, the way every weather widget shows it.
    static func formatTemperature(_ celsius: Double, fahrenheit: Bool) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        let rounded = Int(value.rounded())
        return "\(rounded)°"
    }
}
