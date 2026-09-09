import XCTest
@testable import MacNotchIsland

/// WeatherService's pure logic: the WMO code table, unit formatting, the request URL and
/// the Open-Meteo decoder. Nothing here touches CoreLocation, the network or UserDefaults.
final class WeatherServiceTests: XCTestCase {
    // MARK: - condition(code:isDay:)

    func testClearSkyUsesSunByDayAndMoonByNight() {
        XCTAssertEqual(WeatherService.condition(code: 0, isDay: true).symbol, "sun.max.fill")
        XCTAssertEqual(WeatherService.condition(code: 0, isDay: false).symbol, "moon.stars.fill")
        XCTAssertEqual(WeatherService.condition(code: 0, isDay: true).text, "Clear")
        XCTAssertEqual(WeatherService.condition(code: 0, isDay: false).text, "Clear")
    }

    func testPartlyCloudyCoversBothCodesAndBothTimesOfDay() {
        for code in [1, 2] {
            XCTAssertEqual(WeatherService.condition(code: code, isDay: true).symbol, "cloud.sun.fill")
            XCTAssertEqual(WeatherService.condition(code: code, isDay: false).symbol, "cloud.moon.fill")
            XCTAssertEqual(WeatherService.condition(code: code, isDay: true).text, "Partly cloudy")
        }
    }

    func testOvercastAndFog() {
        XCTAssertEqual(WeatherService.condition(code: 3, isDay: true).symbol, "cloud.fill")
        XCTAssertEqual(WeatherService.condition(code: 3, isDay: true).text, "Overcast")
        for code in [45, 48] {
            XCTAssertEqual(WeatherService.condition(code: code, isDay: true).symbol, "cloud.fog.fill")
            XCTAssertEqual(WeatherService.condition(code: code, isDay: false).text, "Fog")
        }
    }

    func testDrizzleBandIncludesItsEdges() {
        for code in 51...57 {
            XCTAssertEqual(WeatherService.condition(code: code, isDay: true).symbol, "cloud.drizzle.fill", "code \(code)")
            XCTAssertEqual(WeatherService.condition(code: code, isDay: true).text, "Drizzle", "code \(code)")
        }
    }

    func testRainCoversBothItsBands() {
        for code in Array(61...67) + Array(80...82) {
            XCTAssertEqual(WeatherService.condition(code: code, isDay: false).symbol, "cloud.rain.fill", "code \(code)")
            XCTAssertEqual(WeatherService.condition(code: code, isDay: false).text, "Rain", "code \(code)")
        }
    }

    func testSnowCoversBothItsBands() {
        for code in Array(71...77) + Array(85...86) {
            XCTAssertEqual(WeatherService.condition(code: code, isDay: true).symbol, "cloud.snow.fill", "code \(code)")
            XCTAssertEqual(WeatherService.condition(code: code, isDay: true).text, "Snow", "code \(code)")
        }
    }

    func testThunderstormBand() {
        for code in 95...99 {
            XCTAssertEqual(WeatherService.condition(code: code, isDay: true).symbol, "cloud.bolt.rain.fill", "code \(code)")
            XCTAssertEqual(WeatherService.condition(code: code, isDay: true).text, "Thunderstorm", "code \(code)")
        }
    }

    func testUnknownCodesFallBackToPlainCloud() {
        // The gaps between the WMO bands, and anything the API might add later.
        for code in [4, 20, 44, 58, 60, 68, 79, 84, 87, 94, 100, -1] {
            let condition = WeatherService.condition(code: code, isDay: true)
            XCTAssertEqual(condition.symbol, "cloud.fill", "code \(code)")
            XCTAssertEqual(condition.text, "Cloudy", "code \(code)")
        }
    }

    func testNightVariantsOnlyExistWhereTheyMakeSense() {
        // Rain looks the same at midnight; only clear and partly cloudy swap glyphs.
        XCTAssertEqual(WeatherService.condition(code: 63, isDay: true).symbol,
                       WeatherService.condition(code: 63, isDay: false).symbol)
        XCTAssertNotEqual(WeatherService.condition(code: 0, isDay: true).symbol,
                          WeatherService.condition(code: 0, isDay: false).symbol)
    }

    // MARK: - formatTemperature

    func testMetricTemperatureIsWholeCelsius() {
        XCTAssertEqual(WeatherService.formatTemperature(21.4, fahrenheit: false), "21°")
        XCTAssertEqual(WeatherService.formatTemperature(21.6, fahrenheit: false), "22°")
        XCTAssertEqual(WeatherService.formatTemperature(0, fahrenheit: false), "0°")
    }

    func testImperialTemperatureConvertsToFahrenheit() {
        XCTAssertEqual(WeatherService.formatTemperature(0, fahrenheit: true), "32°")
        XCTAssertEqual(WeatherService.formatTemperature(100, fahrenheit: true), "212°")
        XCTAssertEqual(WeatherService.formatTemperature(21.4, fahrenheit: true), "71°")
    }

    func testFreezingTemperaturesKeepTheirSign() {
        XCTAssertEqual(WeatherService.formatTemperature(-3.4, fahrenheit: false), "-3°")
        XCTAssertEqual(WeatherService.formatTemperature(-40, fahrenheit: true), "-40°")
    }

    func testNearZeroNeverPrintsMinusZero() {
        XCTAssertEqual(WeatherService.formatTemperature(-0.4, fahrenheit: false), "0°")
    }

    // MARK: - formatWind

    func testWindFormatting() {
        XCTAssertEqual(WeatherService.formatWind(12.3, milesPerHour: false), "12 km/h")
        XCTAssertEqual(WeatherService.formatWind(0, milesPerHour: false), "0 km/h")
        // 12.3 km/h is 7.6 mph.
        XCTAssertEqual(WeatherService.formatWind(12.3, milesPerHour: true), "8 mph")
        XCTAssertEqual(WeatherService.formatWind(100, milesPerHour: true), "62 mph")
    }

    // MARK: - forecastURL

    func testForecastURLAsksForEverythingThePanelShows() throws {
        let url = try XCTUnwrap(WeatherService.forecastURL(latitude: 52.5244, longitude: 13.4105))
        let text = url.absoluteString
        XCTAssertTrue(text.hasPrefix("https://api.open-meteo.com/v1/forecast?"), text)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["current"], "temperature_2m,weather_code,wind_speed_10m,is_day")
        XCTAssertEqual(values["daily"], "temperature_2m_max,temperature_2m_min")
        XCTAssertEqual(values["timezone"], "auto")
        XCTAssertEqual(values["forecast_days"], "1")
    }

    func testForecastURLRoundsTheCoordinateItSends() throws {
        let url = try XCTUnwrap(WeatherService.forecastURL(latitude: 52.524418, longitude: -13.410530))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["latitude"], "52.524")
        XCTAssertEqual(values["longitude"], "-13.411")
    }

    // MARK: - parse

    private let samplePayload = """
    {
      "latitude": 52.52,
      "longitude": 13.419998,
      "generationtime_ms": 0.0349283218383789,
      "utc_offset_seconds": 7200,
      "timezone": "Europe/Berlin",
      "timezone_abbreviation": "CEST",
      "elevation": 38.0,
      "current_units": {
        "time": "iso8601", "interval": "seconds", "temperature_2m": "°C",
        "weather_code": "wmo code", "wind_speed_10m": "km/h", "is_day": ""
      },
      "current": {
        "time": "2026-09-07T12:15", "interval": 900, "temperature_2m": 21.4,
        "weather_code": 2, "wind_speed_10m": 12.3, "is_day": 1
      },
      "daily_units": {
        "time": "iso8601", "temperature_2m_max": "°C", "temperature_2m_min": "°C"
      },
      "daily": {
        "time": ["2026-09-07"],
        "temperature_2m_max": [24.1],
        "temperature_2m_min": [14.6]
      }
    }
    """

    func testParseSampleOpenMeteoPayload() throws {
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(samplePayload.utf8)))
        XCTAssertEqual(snapshot.temperatureC, 21.4, accuracy: 0.0001)
        XCTAssertEqual(snapshot.weatherCode, 2)
        XCTAssertEqual(snapshot.windKmh, 12.3, accuracy: 0.0001)
        XCTAssertTrue(snapshot.isDay)
        XCTAssertEqual(try XCTUnwrap(snapshot.highC), 24.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.lowC), 14.6, accuracy: 0.0001)
        // The payload knows nothing about the place; the geocoder fills that in later.
        XCTAssertNil(snapshot.placeName)
        XCTAssertEqual(snapshot.updatedAt.timeIntervalSinceNow, 0, accuracy: 5)
    }

    func testParsedSnapshotDrivesTheDisplayedCondition() throws {
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(samplePayload.utf8)))
        let condition = WeatherService.condition(code: snapshot.weatherCode, isDay: snapshot.isDay)
        XCTAssertEqual(condition.symbol, "cloud.sun.fill")
        XCTAssertEqual(condition.text, "Partly cloudy")
    }

    func testParseReadsNightFromIsDayZero() throws {
        let json = """
        {"current": {"temperature_2m": -2.5, "weather_code": 71, "wind_speed_10m": 4, "is_day": 0}}
        """
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(json.utf8)))
        XCTAssertFalse(snapshot.isDay)
        XCTAssertEqual(snapshot.temperatureC, -2.5, accuracy: 0.0001)
        XCTAssertEqual(WeatherService.condition(code: snapshot.weatherCode, isDay: snapshot.isDay).text, "Snow")
    }

    func testParseWithoutDailyBlockLeavesHighAndLowNil() throws {
        let json = """
        {"current": {"temperature_2m": 9, "weather_code": 3, "wind_speed_10m": 11, "is_day": 1}}
        """
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(json.utf8)))
        XCTAssertNil(snapshot.highC)
        XCTAssertNil(snapshot.lowC)
        XCTAssertEqual(snapshot.windKmh, 11, accuracy: 0.0001)
    }

    func testParseWithEmptyDailyArraysLeavesHighAndLowNil() throws {
        let json = """
        {"current": {"temperature_2m": 9, "weather_code": 3, "wind_speed_10m": 11, "is_day": 1},
         "daily": {"time": [], "temperature_2m_max": [], "temperature_2m_min": []}}
        """
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(json.utf8)))
        XCTAssertNil(snapshot.highC)
        XCTAssertNil(snapshot.lowC)
    }

    func testParseTakesOnlyTheFirstDayOfTheDailyArrays() throws {
        let json = """
        {"current": {"temperature_2m": 9, "weather_code": 3, "wind_speed_10m": 11, "is_day": 1},
         "daily": {"time": ["2026-09-07", "2026-09-08"],
                   "temperature_2m_max": [24.1, 30.0],
                   "temperature_2m_min": [14.6, 18.0]}}
        """
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(json.utf8)))
        XCTAssertEqual(try XCTUnwrap(snapshot.highC), 24.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.lowC), 14.6, accuracy: 0.0001)
    }

    func testParseDefaultsMissingWindAndIsDay() throws {
        let json = """
        {"current": {"temperature_2m": 17, "weather_code": 0}}
        """
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(json.utf8)))
        XCTAssertEqual(snapshot.windKmh, 0, accuracy: 0.0001)
        XCTAssertTrue(snapshot.isDay, "A payload without is_day should read as daytime, not midnight.")
    }

    func testParseReturnsNilForGarbageOrMissingCurrentBlock() {
        XCTAssertNil(WeatherService.parse(Data("not json".utf8)))
        XCTAssertNil(WeatherService.parse(Data("{}".utf8)))
        XCTAssertNil(WeatherService.parse(Data(#"{"daily": {"temperature_2m_max": [1]}}"#.utf8)))
        XCTAssertNil(WeatherService.parse(Data(#"{"current": {"weather_code": 1}}"#.utf8)))
    }

    // MARK: - Snapshot round-trip (the UserDefaults cache)

    func testSnapshotSurvivesJSONRoundTrip() throws {
        let original = WeatherService.Snapshot(temperatureC: 21.4, weatherCode: 2, windKmh: 12.3,
                                               isDay: true, highC: 24.1, lowC: 14.6,
                                               placeName: "Berlin",
                                               updatedAt: Date(timeIntervalSince1970: 1_757_246_100))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WeatherService.Snapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }
    // MARK: - Which units, for whom

    /// Three measurement systems, not two. Britain takes its temperature in Celsius and its
    /// speed in miles per hour, and one flag for both put Fahrenheit in front of every reader
    /// there.
    func testTheUnitedKingdomGetsCelsiusAndMilesPerHour() {
        for (system, fahrenheit, mph) in [(Locale.MeasurementSystem.metric, false, false),
                                          (.uk, false, true),
                                          (.us, true, true)] {
            XCTAssertEqual(system == .us, fahrenheit, "\(system) and Fahrenheit")
            XCTAssertEqual(system != .metric, mph, "\(system) and miles per hour")
        }
        XCTAssertEqual(WeatherService.formatTemperature(21.4, fahrenheit: false), "21°")
        XCTAssertEqual(WeatherService.formatWind(12.3, milesPerHour: true), "8 mph")
    }


    // MARK: - The next few hours

    private func times(_ offsets: [Int], from now: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return offsets.map { formatter.string(from: now.addingTimeInterval(Double($0) * 3600)) }
    }

    func testTheStripStartsAfterNowAndStopsAtSix() {
        let now = Date()
        let stamps = times(Array(-3...12), from: now)
        let block = WeatherService.Forecast.Hourly(time: stamps,
                                                   temperature: stamps.indices.map { Double($0) },
                                                   weatherCode: stamps.map { _ in 3 },
                                                   isDay: stamps.map { _ in 1 })
        let hours = WeatherService.hours(from: block, now: now)
        XCTAssertEqual(hours.count, WeatherService.hoursAhead)
        XCTAssertTrue(hours.allSatisfy { $0.date > now }, "an hour that has been is not a forecast")
        XCTAssertEqual(hours, hours.sorted { $0.date < $1.date }, "in the order they will happen")
        XCTAssertTrue(hours.allSatisfy { $0.isDay })
    }

    func testAShortAnswerIsNotReadOffTheEndOf() {
        // The arrays come back parallel; one of them being short is a malformed answer, not a
        // reason to walk off the end of it.
        let now = Date()
        let stamps = times([1, 2, 3, 4], from: now)
        let block = WeatherService.Forecast.Hourly(time: stamps, temperature: [10, 11],
                                                   weatherCode: nil, isDay: nil)
        let hours = WeatherService.hours(from: block, now: now)
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours.map(\.weatherCode), [0, 0], "no code is a clear sky, not a crash")
    }

    func testNoHourlyBlockIsNoStrip() {
        XCTAssertTrue(WeatherService.hours(from: nil).isEmpty)
        XCTAssertTrue(WeatherService.hours(from: WeatherService.Forecast.Hourly(time: nil, temperature: nil,
                                                                               weatherCode: nil, isDay: nil)).isEmpty)
    }

    func testAnHourIsLabelledTheWayTheClockIs() {
        let calendar = Calendar.current
        let afternoon = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
        let label = TodaySectionView.hourLabel(afternoon, calendar: calendar)
        XCTAssertTrue(label == "17" || label == "5 PM", label)
    }
}
