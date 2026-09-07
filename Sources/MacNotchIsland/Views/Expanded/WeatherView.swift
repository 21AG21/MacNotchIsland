import AppKit
import SwiftUI

/// The Home panel's "Weather" tab: the temperature and today's high/low on the left, where
/// the eye lands, and the place, wind and age of the reading on the right. Same grammar as
/// the Stats tab — small grey label, big white value, no boxes.
///
/// CoreLocation and the network only run while this is on screen: `start()` / `stop()` are
/// reference counted on `WeatherService`.
struct WeatherView: View {
    @ObservedObject private var weather = WeatherService.shared

    private static let temperatureFont = Font.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit()

    /// "Updated 5 min ago" — abbreviated so it never crowds the place name.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { WeatherService.shared.start() }
            .onDisappear { WeatherService.shared.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch weather.state {
        case .ready:
            reading
        case .idle, .locating, .loading:
            // A cached reading stays on screen through a background refresh; only a panel
            // with nothing to show gets the placeholder.
            if weather.temperatureC != nil {
                reading
            } else {
                message("Finding your weather…")
            }
        case .denied:
            prompt(title: "Location access is off", button: "Open Settings", symbol: "gearshape.fill") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .failed:
            prompt(title: "Weather unavailable", button: "Retry", symbol: "arrow.clockwise") {
                weather.refresh()
            }
        }
    }

    // MARK: - The reading

    private var reading: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 10) {
                    Text(temperatureText)
                        .font(Self.temperatureFont)
                        .foregroundStyle(.white)
                    Image(systemName: weather.conditionSymbol)
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let place = weather.placeName {
                    Text(place)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if let wind = windText {
                    Text(wind)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                if let updated = updatedText {
                    Text(updated)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 200, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Text

    private var usesMetric: Bool { WeatherService.usesMetric }

    private var temperatureText: String {
        guard let celsius = weather.temperatureC else { return "—" }
        return WeatherService.formatTemperature(celsius, usesMetric: usesMetric)
    }

    /// "Partly cloudy · H 24° L 15°", dropping whichever half is missing.
    private var detailText: String {
        var parts: [String] = []
        if !weather.conditionText.isEmpty { parts.append(weather.conditionText) }
        var range: [String] = []
        if let high = weather.highC {
            range.append("H " + WeatherService.formatTemperature(high, usesMetric: usesMetric))
        }
        if let low = weather.lowC {
            range.append("L " + WeatherService.formatTemperature(low, usesMetric: usesMetric))
        }
        if !range.isEmpty { parts.append(range.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    private var windText: String? {
        guard let kmh = weather.windKmh else { return nil }
        return "Wind " + WeatherService.formatWind(kmh, usesMetric: usesMetric)
    }

    private var updatedText: String? {
        guard let updatedAt = weather.updatedAt else { return nil }
        let age = Date().timeIntervalSince(updatedAt)
        if age < 60 { return "Updated just now" }
        return "Updated " + Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date())
    }

    // MARK: - Placeholders

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func prompt(title: String, button: String, symbol: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            PillButton(title: button, symbol: symbol, action: action)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
