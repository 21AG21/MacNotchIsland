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

    // MARK: - forecastURL

    func testForecastURLAsksForEverythingThePanelShows() throws {
        let url = try XCTUnwrap(WeatherService.forecastURL(latitude: 52.5244, longitude: 13.4105))
        let text = url.absoluteString
        XCTAssertTrue(text.hasPrefix("https://api.open-meteo.com/v1/forecast?"), text)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["current"], "temperature_2m,weather_code,is_day",
                       "only what is drawn: the wind was asked for and shown nowhere")
        XCTAssertEqual(values["daily"], "temperature_2m_max,temperature_2m_min")
        XCTAssertEqual(values["hourly"], "temperature_2m,weather_code,is_day")
        XCTAssertEqual(values["timezone"], "auto")
        XCTAssertEqual(values["timeformat"], "unixtime",
                       "the hours as moments: a wall clock is not one on the nights it is changed")
        // Two, because "the next six hours" at nine in the evening is tomorrow.
        XCTAssertEqual(values["forecast_days"], "2")
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

    func testParseDefaultsMissingIsDay() throws {
        let json = """
        {"current": {"temperature_2m": 17, "weather_code": 0}}
        """
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(json.utf8)))
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
        let original = WeatherService.Snapshot(temperatureC: 21.4, weatherCode: 2,
                                               isDay: true, highC: 24.1, lowC: 14.6,
                                               placeName: "Berlin",
                                               updatedAt: Date(timeIntervalSince1970: 1_757_246_100),
                                               timeZone: "Europe/Berlin", utcOffset: 7200)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WeatherService.Snapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testAReadingCachedWithTheWindInItStillReadsBack() throws {
        // A build that asked for the wind cached it with every reading, and a relaunch after
        // updating must not come up with nothing to show for want of a field it no longer has.
        let json = """
        {"temperatureC": 9, "weatherCode": 3, "windKmh": 11, "isDay": true,
         "updatedAt": 0, "hours": []}
        """
        let decoded = try JSONDecoder().decode(WeatherService.Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.temperatureC, 9, accuracy: 0.0001)
        XCTAssertNil(decoded.timeZone, "a reading cached before the zone was kept has none, and is read all the same")
    }

    // MARK: - How old a reading is

    private let taken = Date(timeIntervalSince1970: 1_790_000_000)
    private let hour: TimeInterval = 3600

    /// The cache kept a reading of any age and Today showed it as the weather, so a Mac that
    /// went offline, or refused its location, said "18° · Clear" for good.
    func testAReadingIsTheWeatherForThreeRefreshes() {
        let interval = WeatherService.refreshInterval
        XCTAssertEqual(WeatherService.age(of: taken, at: taken), .current)
        XCTAssertEqual(WeatherService.age(of: taken, at: taken.addingTimeInterval(3 * interval - 1)), .current)
        XCTAssertEqual(WeatherService.age(of: taken, at: taken.addingTimeInterval(3 * interval)), .old("1 hr ago"),
                       "three refreshes missed is a Mac that is not getting the weather, and the line says so")
    }

    func testAnOldReadingSaysHowOldAndAnAncientOneIsNotShown() {
        XCTAssertEqual(WeatherService.age(of: taken, at: taken.addingTimeInterval(5 * hour)), .old("5 hrs ago"))
        XCTAssertEqual(WeatherService.age(of: taken, at: taken.addingTimeInterval(23.9 * hour)), .old("23 hrs ago"))
        XCTAssertEqual(WeatherService.age(of: taken, at: taken.addingTimeInterval(24 * hour)), .expired,
                       "yesterday's temperature is not a fact about today")
        XCTAssertEqual(WeatherService.age(of: nil, at: taken), .expired, "no reading is nothing to show")
    }

    func testOnBatteryAReadingIsGivenTheLongerRefreshItIsOn() {
        // Low Power Mode stretches the refresh fourfold, to every two hours; a reading that is
        // not due again until then is not old at three.
        let lowPower = WeatherService.refreshInterval * EnergyPolicy.pollingMultiplier(asleep: false, lowPower: true,
                                                                                       onBattery: true)
        XCTAssertEqual(WeatherService.age(of: taken, interval: lowPower, at: taken.addingTimeInterval(3 * hour)), .current)
    }

    func testAReadingFromTheFutureIsAClockThatWasSetBack() {
        XCTAssertEqual(WeatherService.age(of: taken, at: taken.addingTimeInterval(-10 * 60)), .current)
        XCTAssertEqual(WeatherService.age(of: taken, at: taken.addingTimeInterval(-48 * hour)), .expired,
                       "how old it is cannot be known, and it is not taken for new")
    }

    func testTheLineSaysHowOldTheReadingIs() {
        XCTAssertEqual(TodaySectionView.weatherText(celsius: 18, condition: "Clear", age: .current, fahrenheit: false),
                       "18° · Clear")
        XCTAssertEqual(TodaySectionView.weatherText(celsius: 18, condition: "Clear", age: .old("3 hrs ago"),
                                                    fahrenheit: false),
                       "18° · Clear · 3 hrs ago")
        XCTAssertEqual(TodaySectionView.weatherText(celsius: 18, condition: "", age: .current, fahrenheit: false), "18°")
        XCTAssertNil(TodaySectionView.weatherText(celsius: 18, condition: "Clear", age: .expired, fahrenheit: false),
                     "a reading too old to be the weather is not put up as one")
    }

    // MARK: - Which units, for whom

    private func fahrenheit(_ identifier: String) -> Bool {
        WeatherService.isFahrenheit(for: Locale(identifier: identifier))
    }

    /// The United States reads the weather in Fahrenheit; Britain, with a measurement system of
    /// its own, and everywhere metric, in Celsius.
    func testTheUnitedStatesGetsFahrenheitAndBritainCelsius() {
        XCTAssertTrue(fahrenheit("en_US"))
        XCTAssertFalse(fahrenheit("en_GB"), "Britain is not metric, and takes its temperature in Celsius")
        XCTAssertFalse(fahrenheit("de_DE"))
        XCTAssertFalse(fahrenheit("fr_CA"))
    }

    /// The scale was read off the measurement system, and a temperature is not a length: Puerto
    /// Rico measures in metres and reads the weather in Fahrenheit, Liberia the other way about.
    func testTheScaleIsTheRegionsOwnNotItsMeasurementSystem() {
        XCTAssertTrue(fahrenheit("es_PR"), "metric, and Fahrenheit")
        XCTAssertFalse(fahrenheit("en_LR"), "the American system, and Celsius")
        XCTAssertEqual(WeatherService.formatTemperature(21.4, fahrenheit: fahrenheit("es_PR")), "71°")
    }


    // MARK: - The next few hours

    /// Hours from `now`, as the answer gives them: seconds since 1970.
    private func times(_ offsets: [Int], from now: Date) -> [TimeInterval] {
        offsets.map { now.addingTimeInterval(Double($0) * 3600).timeIntervalSince1970 }
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

    func testACachedForecastOnlyShowsTheHoursStillToCome() {
        // The strip is cached as it was fetched, so a morning relaunch with no network put
        // last night's evening up as the next six hours.
        let now = Date()
        let evening = (-12 ... -7).map { offset in
            WeatherService.Hour(date: now.addingTimeInterval(Double(offset) * 3600), temperatureC: 12,
                                weatherCode: 3, isDay: false)
        }
        XCTAssertTrue(WeatherService.upcoming(evening, after: now).isEmpty, "all of it has been")
        let later = WeatherService.Hour(date: now.addingTimeInterval(3600), temperatureC: 14,
                                        weatherCode: 1, isDay: true)
        XCTAssertEqual(WeatherService.upcoming(evening + [later], after: now), [later])
    }

    func testNoHourlyBlockIsNoStrip() {
        XCTAssertTrue(WeatherService.hours(from: nil).isEmpty)
        XCTAssertTrue(WeatherService.hours(from: WeatherService.Forecast.Hourly(time: nil, temperature: nil,
                                                                               weatherCode: nil, isDay: nil)).isEmpty)
    }

    // MARK: - How an hour is labelled

    private let utc = TimeZone(identifier: "UTC")!
    /// Five in the afternoon, UTC.
    private let five = Date(timeIntervalSince1970: 1_790_010_000)

    /// A narrow or a plain no-break space is what CLDR puts between a figure and "PM" now; a
    /// space is a space for these.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func hourText(_ identifier: String, spoken: Bool = false) -> String {
        TodaySectionView.hourLabel(five, spoken: spoken, timeZone: utc, locale: Locale(identifier: identifier))
    }

    func testTheFixtureIsFiveInTheAfternoon() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        XCTAssertEqual(calendar.component(.hour, from: five), 17)
        XCTAssertEqual(calendar.component(.minute, from: five), 0)
    }

    /// The strip wrote "AM" and "PM" itself, which is only how American English writes them,
    /// and the bare number everywhere else.
    func testAnHourIsWrittenTheWayTheLocaleWritesIt() {
        XCTAssertEqual(plain(hourText("en_US")), "5 PM")
        XCTAssertEqual(hourText("en_GB"), "17", "a 24-hour region writes the hour alone")
        let french = hourText("fr_FR")
        XCTAssertTrue(french.hasPrefix("17"), french)
        XCTAssertFalse(french.contains("PM"), french)
        XCTAssertEqual(french, LiveDateFormatter.make(locale: Locale(identifier: "fr_FR"), timeZone: utc) {
            $0.setLocalizedDateFormatFromTemplate("j")
        }.string(from: five), "whatever the locale's own template makes of it")
    }

    /// VoiceOver read "17" out as a number; "17:00" is read as a time.
    func testASpokenHourIsATime() {
        XCTAssertEqual(hourText("en_GB", spoken: true), "17:00")
        XCTAssertEqual(plain(hourText("en_US", spoken: true)), "5:00 PM")
    }

    /// The hours are the forecast's, and are written in its zone: five in the afternoon in
    /// London is two in the morning in Tokyo.
    func testAnHourIsWrittenInTheZoneItIsGivenIn() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(TodaySectionView.hourLabel(five, timeZone: tokyo, locale: Locale(identifier: "en_GB")), "02")
    }

    /// The kept formatter is the same one until the settings change, and a new one after.
    func testTheKeptFormatterIsMadeAgainWhenTheSettingsChange() {
        let kept = LiveDateFormatter { $0.setLocalizedDateFormatFromTemplate("j") }
        let first = kept.formatter()
        XCTAssertTrue(first === kept.formatter(), "made once, and kept")
        XCTAssertFalse(first === kept.formatter(timeZone: utc), "a zone of its own is a formatter of its own")
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        XCTAssertFalse(first === kept.formatter(), "the 24-hour switch, the region or the language changed")
    }

    // MARK: - The zone a forecast is written in

    func testTheForecastsOwnZoneIsTheOneItsTimesAreIn() {
        XCTAssertEqual(WeatherService.forecastZone(identifier: "Europe/Berlin", offset: 7200)?.identifier, "Europe/Berlin")
        XCTAssertEqual(WeatherService.forecastZone(identifier: "Not/AZone", offset: -18000)?.secondsFromGMT(), -18000,
                       "the offset when the name is not one this Mac knows")
        XCTAssertEqual(WeatherService.forecastZone(identifier: nil, offset: 3600)?.secondsFromGMT(), 3600)
        XCTAssertNil(WeatherService.forecastZone(identifier: nil, offset: nil))
    }

    /// The times are moments, whatever zone the Mac or the place is in: the moment the answer
    /// gives is the moment of the hour.
    func testTheHoursAreTheMomentsTheAnswerGives() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-26T00:00:00Z"))
        let block = WeatherService.Forecast.Hourly(time: [now.timeIntervalSince1970 + 3600, now.timeIntervalSince1970 + 7200],
                                                   temperature: [20, 21], weatherCode: [1, 2], isDay: [1, 1])
        XCTAssertEqual(WeatherService.hours(from: block, now: now).map(\.date),
                       [now.addingTimeInterval(3600), now.addingTimeInterval(7200)])
    }

    /// 1 November 2026 in New York: one in the morning comes round twice. As wall-clock times it
    /// was one moment twice, two hours with the same id in the strip; as moments it is two.
    func testTheHourAutumnRepeatsIsTwoHours() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // 05:00 UTC is 1:00 EDT; 06:00 UTC is 1:00 EST, the hour over again; 07:00 UTC is 2:00 EST.
        let first = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T05:00:00Z"))
        let stamps = [0, 1, 2].map { first.timeIntervalSince1970 + Double($0) * 3600 }
        let block = WeatherService.Forecast.Hourly(time: stamps, temperature: [8, 8, 7], weatherCode: nil, isDay: nil)
        let hours = WeatherService.hours(from: block, now: first.addingTimeInterval(-1))
        XCTAssertEqual(hours.count, 3)
        XCTAssertEqual(Set(hours.map(\.id)).count, 3, "three hours, three ids")
        let labels = hours.map { TodaySectionView.hourLabel($0.date, timeZone: newYork, locale: Locale(identifier: "en_GB")) }
        XCTAssertEqual(labels, ["01", "01", "02"], "and the one that comes round again is labelled as the clock reads it")
    }

    /// 8 March 2026 in New York: two in the morning never happens. As a wall-clock time it would
    /// not read, and was dropped with the hour after it misplaced; as moments nothing is missing.
    func testTheHourSpringSkipsLeavesNoGap() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // 06:00 UTC is 1:00 EST; 07:00 UTC is 3:00 EDT.
        let first = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T06:00:00Z"))
        let stamps = [0, 1].map { first.timeIntervalSince1970 + Double($0) * 3600 }
        let block = WeatherService.Forecast.Hourly(time: stamps, temperature: [2, 3], weatherCode: [0, 0], isDay: [0, 0])
        let hours = WeatherService.hours(from: block, now: first.addingTimeInterval(-1))
        XCTAssertEqual(hours.map(\.date), [first, first.addingTimeInterval(3600)])
        XCTAssertEqual(hours.map { TodaySectionView.hourLabel($0.date, timeZone: newYork, locale: Locale(identifier: "en_GB")) },
                       ["01", "03"])
    }

    /// The strip is drawn by id, which is the moment: an answer that gave one twice would draw
    /// one hour twice.
    func testAnHourGivenTwiceIsShownOnce() {
        let now = Date()
        let stamps = times([1, 1, 2], from: now)
        let block = WeatherService.Forecast.Hourly(time: stamps, temperature: [10, 10, 11], weatherCode: nil, isDay: nil)
        XCTAssertEqual(WeatherService.hours(from: block, now: now).map(\.temperatureC), [10, 11])
    }

    func testTheParsedForecastKeepsTheZoneItNames() throws {
        // 2999-01-01T00:00:00Z, which is nine in the morning in Tokyo.
        let json = """
        {"utc_offset_seconds": 32400, "timezone": "Asia/Tokyo",
         "current": {"time": 32472144000, "temperature_2m": 20, "weather_code": 1, "is_day": 1},
         "daily": {"time": [32472111600], "temperature_2m_max": [24], "temperature_2m_min": [15]},
         "hourly": {"time": [32472144000], "temperature_2m": [20], "weather_code": [1], "is_day": [1]}}
        """
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(json.utf8)))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2999-01-01T00:00:00Z"))
        XCTAssertEqual(snapshot.hours.first?.date, expected)
        XCTAssertEqual(snapshot.timeZone, "Asia/Tokyo")
        XCTAssertEqual(snapshot.utcOffset, 32400)
        XCTAssertEqual(WeatherService.forecastZone(identifier: snapshot.timeZone, offset: snapshot.utcOffset)?.identifier,
                       "Asia/Tokyo", "the zone the strip labels the hours in")
        XCTAssertEqual(try XCTUnwrap(snapshot.highC), 24, accuracy: 0.0001)
    }

    /// An hourly block in some other shape is no strip; the reading above it still stands.
    func testHoursWrittenAsTextAreNoStripButTheReadingStands() throws {
        let json = """
        {"current": {"temperature_2m": 20, "weather_code": 1, "is_day": 1},
         "hourly": {"time": ["2999-01-01T09:00"], "temperature_2m": [20], "weather_code": [1], "is_day": [1]}}
        """
        let snapshot = try XCTUnwrap(WeatherService.parse(Data(json.utf8)))
        XCTAssertEqual(snapshot.temperatureC, 20, accuracy: 0.0001)
        XCTAssertTrue(snapshot.hours.isEmpty)
    }
}
