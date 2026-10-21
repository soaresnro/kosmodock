import Foundation
import Observation

// The weather widget, the only one that makes internet requests itself. It
// uses Open-Meteo (open-meteo.com), which needs no account or key: Kosmodock
// sends it the city you search for and the chosen place's coordinates, only
// while a weather tile is on the bar, and never asks for your location.

struct WeatherLocation: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    /// State and country, to tell places with the same name apart.
    var detail: String?

    var id: String { "\(latitude),\(longitude)" }
    var title: String { [name, detail ?? ""].filter { !$0.isEmpty }.joined(separator: ", ") }
}

extension WeatherLocation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // No sensible default for a place without coordinates: it's reported.
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        name = try c.decode(.name, or: "")
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

enum TemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }

    /// macOS's temperature setting, else Fahrenheit where the region measures
    /// in US units.
    static var preferred: TemperatureUnit {
        if let saved = UserDefaults.standard.string(forKey: "AppleTemperatureUnit") {
            return saved == "Fahrenheit" ? .fahrenheit : .celsius
        }
        return Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }

    func value(ofCelsius celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// "21°", rounded, never "-0°".
    func degrees(_ celsius: Double) -> String {
        "\(Int(value(ofCelsius: celsius).rounded()))°"
    }
}

struct WeatherOptions: Codable, Equatable, Sendable {
    var location: WeatherLocation?
    /// nil follows macOS.
    var unit: TemperatureUnit?

    var resolvedUnit: TemperatureUnit { unit ?? .preferred }
}

extension WeatherOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        location = try c.decodeIfPresent(WeatherLocation.self, forKey: .location)
        unit = try c.decodeIfPresent(TemperatureUnit.self, forKey: .unit)
    }
}

// MARK: - Conditions

/// The WMO weather codes Open-Meteo reports, grouped as the widget shows them.
enum WeatherCondition: Equatable, Sendable {
    case clear
    case mainlyClear
    case partlyCloudy
    case overcast
    case fog
    case drizzle
    case freezingDrizzle
    case rain
    case heavyRain
    case freezingRain
    case snow
    case heavySnow
    case snowGrains
    case showers
    case heavyShowers
    case snowShowers
    case thunderstorm
    case hail
    case unknown

    init(code: Int) {
        switch code {
        case 0: self = .clear
        case 1: self = .mainlyClear
        case 2: self = .partlyCloudy
        case 3: self = .overcast
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57: self = .freezingDrizzle
        case 61, 63: self = .rain
        case 65: self = .heavyRain
        case 66, 67: self = .freezingRain
        case 71, 73: self = .snow
        case 75: self = .heavySnow
        case 77: self = .snowGrains
        case 80, 81: self = .showers
        case 82: self = .heavyShowers
        case 85, 86: self = .snowShowers
        case 95: self = .thunderstorm
        case 96, 99: self = .hail
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .clear: L10n.tr("Clear sky")
        case .mainlyClear: L10n.tr("Mainly clear")
        case .partlyCloudy: L10n.tr("Partly cloudy")
        case .overcast: L10n.tr("Overcast")
        case .fog: L10n.tr("Fog")
        case .drizzle: L10n.tr("Drizzle")
        case .freezingDrizzle: L10n.tr("Freezing drizzle")
        case .rain: L10n.tr("Rain")
        case .heavyRain: L10n.tr("Heavy rain")
        case .freezingRain: L10n.tr("Freezing rain")
        case .snow: L10n.tr("Snow")
        case .heavySnow: L10n.tr("Heavy snow")
        case .snowGrains: L10n.tr("Snow grains")
        case .showers: L10n.tr("Rain showers")
        case .heavyShowers: L10n.tr("Heavy showers")
        case .snowShowers: L10n.tr("Snow showers")
        case .thunderstorm: L10n.tr("Thunderstorm")
        case .hail: L10n.tr("Thunderstorm with hail")
        case .unknown: L10n.tr("Unknown")
        }
    }

    /// SF Symbols with color layers (`.multicolor`); night variants for the
    /// current reading.
    func symbol(isDay: Bool = true) -> String {
        switch self {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .mainlyClear: isDay ? "sun.max.fill" : "moon.fill"
        case .partlyCloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .freezingDrizzle, .freezingRain: "cloud.sleet.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain, .heavyShowers: "cloud.heavyrain.fill"
        case .snow, .snowShowers: "cloud.snow.fill"
        case .heavySnow: "snowflake"
        case .snowGrains: "cloud.snow"
        case .showers: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        case .hail: "cloud.hail.fill"
        case .unknown: "thermometer.medium"
        }
    }
}

// MARK: - Open-Meteo

struct WeatherDay: Equatable, Identifiable, Sendable {
    /// "2026-10-21", in the place's time zone.
    var date: String
    var code: Int
    /// °C.
    var high: Double
    var low: Double

    var id: String { date }
    var condition: WeatherCondition { WeatherCondition(code: code) }
}

struct WeatherReport: Equatable, Sendable {
    /// °C.
    var temperature: Double
    var feelsLike: Double
    var code: Int
    var isDay: Bool
    /// Today first.
    var days: [WeatherDay]
    var updatedAt: Date

    var condition: WeatherCondition { WeatherCondition(code: code) }
}

enum OpenMeteo {
    static let forecastDays = 5

    struct Failure: LocalizedError, Equatable {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// Celsius always: the widget converts, so switching units needs no request.
    static func forecastURL(for location: WeatherLocation) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", location.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "\(forecastDays)"),
        ]
        return components?.url
    }

    /// Place names in `language` ("en", "pt", "es").
    static func searchURL(for name: String, language: String) -> URL? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    /// The interface language's code for the geocoding search.
    static var language: String {
        L10n.locale.language.languageCode?.identifier ?? "en"
    }

    private struct ErrorResponse: Decodable {
        var error: Bool?
        var reason: String?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            var temperature: Double?
            var feelsLike: Double?
            var code: Int?
            var isDay: Int?

            enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m"
                case feelsLike = "apparent_temperature"
                case code = "weather_code"
                case isDay = "is_day"
            }
        }

        struct Daily: Decodable {
            var time: [String]
            var code: [Int?]?
            var high: [Double?]?
            var low: [Double?]?

            enum CodingKeys: String, CodingKey {
                case time
                case code = "weather_code"
                case high = "temperature_2m_max"
                case low = "temperature_2m_min"
            }
        }

        var current: Current?
        var daily: Daily?
    }

    /// A forecast answer; Open-Meteo's own error (`{"error": true,
    /// "reason": …}`) is thrown with its reason.
    static func report(from data: Data, now: Date = Date()) throws -> WeatherReport {
        if let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data), failure.error == true {
            throw Failure(reason: failure.reason ?? L10n.tr("Unexpected answer from Open-Meteo"))
        }
        let response = try JSONDecoder().decode(ForecastResponse.self, from: data)
        guard let current = response.current, let temperature = current.temperature else {
            throw Failure(reason: L10n.tr("Unexpected answer from Open-Meteo"))
        }
        var days: [WeatherDay] = []
        if let daily = response.daily {
            for (index, date) in daily.time.enumerated() {
                guard let high = daily.high?[safe: index] ?? nil, let low = daily.low?[safe: index] ?? nil else { continue }
                days.append(WeatherDay(date: date, code: (daily.code?[safe: index] ?? nil) ?? -1, high: high, low: low))
            }
        }
        return WeatherReport(
            temperature: temperature,
            feelsLike: current.feelsLike ?? temperature,
            code: current.code ?? -1,
            isDay: (current.isDay ?? 1) != 0,
            days: Array(days.prefix(forecastDays)),
            updatedAt: now
        )
    }

    private struct SearchResponse: Decodable {
        struct Place: Decodable {
            var name: String
            var latitude: Double
            var longitude: Double
            var admin1: String?
            var country: String?
        }

        /// Missing when nothing matched.
        var results: [Place]?
    }

    static func places(from data: Data) throws -> [WeatherLocation] {
        if let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data), failure.error == true {
            throw Failure(reason: failure.reason ?? L10n.tr("Unexpected answer from Open-Meteo"))
        }
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return (response.results ?? []).map { place in
            let detail = [place.admin1, place.country].compactMap { $0 }.filter { !$0.isEmpty && $0 != place.name }
            return WeatherLocation(
                name: place.name, latitude: place.latitude, longitude: place.longitude,
                detail: detail.isEmpty ? nil : detail.joined(separator: ", ")
            )
        }
    }

    /// "Today", then short weekdays ("Wed"), for a daily date string.
    static func dayLabel(_ date: String, isFirst: Bool, locale: Locale = L10n.locale) -> String {
        if isFirst { return L10n.tr("Today") }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard parts.count == 3, let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return date }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).locale(locale)
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Service

/// Readings by tile id, refreshed every 20 minutes and when the details open.
@MainActor
@Observable
final class WeatherService {
    struct Entry: Equatable, Sendable {
        var location: WeatherLocation
        var report: WeatherReport?
        var error: String?
        var isLoading = false
    }

    private(set) var entries: [String: Entry] = [:]

    /// Debug snapshots: never makes a request.
    @ObservationIgnored var isPreview = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: [String: Date] = [:]
    @ObservationIgnored private let session: URLSession = {
        // Nothing kept on disk: no cache, no cookies.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    static let refreshInterval: TimeInterval = 20 * 60
    /// Opening the details again soon after doesn't ask again.
    static let minimumInterval: TimeInterval = 90
    /// After a failure.
    static let retryInterval: TimeInterval = 3 * 60

    /// Follows the weather tiles on the bar: a new or moved place is fetched
    /// at once; without tiles, nothing runs.
    func update(tiles: [DockTile]) {
        var locations: [String: WeatherLocation] = [:]
        for tile in tiles {
            if let location = tile.weather?.location { locations[tile.id] = location }
        }
        for id in entries.keys where locations[id] == nil {
            entries[id] = nil
            lastAttempt[id] = nil
        }
        for (id, location) in locations where entries[id]?.location != location {
            entries[id] = Entry(location: location)
            lastAttempt[id] = nil
            refresh(tileID: id, force: true)
        }
        let active = !locations.isEmpty && !isPreview
        if active, loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    self?.refreshStale()
                }
            }
        } else if !active {
            loop?.cancel()
            loop = nil
        }
    }

    private func refreshStale(now: Date = Date()) {
        for (id, entry) in entries {
            let wait = entry.report == nil || entry.error != nil ? Self.retryInterval : Self.refreshInterval
            if lastAttempt[id].map({ now.timeIntervalSince($0) >= wait }) ?? true { refresh(tileID: id, force: true) }
        }
    }

    func refresh(tileID: String, force: Bool) {
        guard !isPreview, var entry = entries[tileID], !entry.isLoading,
              let url = OpenMeteo.forecastURL(for: entry.location)
        else { return }
        let now = Date()
        if !force, let last = lastAttempt[tileID], now.timeIntervalSince(last) < Self.minimumInterval { return }
        lastAttempt[tileID] = now
        entry.isLoading = true
        entries[tileID] = entry
        let location = entry.location
        let session = session
        Task { [weak self] in
            let result: Result<WeatherReport, Error>
            do {
                let (data, response) = try await session.data(from: url)
                result = .success(try Self.report(from: data, response: response))
            } catch {
                result = .failure(error)
            }
            guard let self, var current = self.entries[tileID], current.location == location else { return }
            current.isLoading = false
            switch result {
            case .success(let report):
                current.report = report
                current.error = nil
            case .failure(let error):
                current.error = error.localizedDescription
            }
            if current != self.entries[tileID] { self.entries[tileID] = current }
        }
    }

    private nonisolated static func report(from data: Data, response: URLResponse) throws -> WeatherReport {
        do {
            return try OpenMeteo.report(from: data)
        } catch let failure as OpenMeteo.Failure {
            throw failure
        } catch {
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw OpenMeteo.Failure(reason: L10n.tr("Open-Meteo answered with HTTP %lld", http.statusCode))
            }
            throw error
        }
    }

    /// Places named like `query`, for choosing the tile's city.
    func search(_ query: String) async throws -> [WeatherLocation] {
        guard !isPreview, let url = OpenMeteo.searchURL(for: query, language: OpenMeteo.language) else { return [] }
        let (data, _) = try await session.data(from: url)
        return try OpenMeteo.places(from: data)
    }

    #if DEBUG
    /// Snapshots: a sample reading, in memory only.
    func injectPreview(_ report: WeatherReport, location: WeatherLocation, tileID: String) {
        isPreview = true
        entries[tileID] = Entry(location: location, report: report)
    }
    #endif
}
