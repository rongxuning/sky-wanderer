import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux Swift. Apple targets export URLSession from Foundation.
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif

/// Historical weather and the start-point place name for one workout.
/// Weather comes from Open-Meteo. The place name comes from `CLGeocoder`.
enum WorkoutContext {
    struct Patch {
        var conditions: WorkoutConditions?
        var startPlace: WorkoutStartPlace?
    }

    static func load(_ workout: WorkoutRecord, now: Date = Date()) async -> Patch {
        guard let point = workout.startCoordinate else { return Patch() }
        let needsWeather = workout.conditions?.weatherReady != true
        let needsAir = workout.conditions?.airReady != true
        let needsPlace = workout.startPlace == nil
        guard needsWeather || needsAir || needsPlace else { return Patch() }

        async let conditions = fetchConditions(
            latitude: point.latitude,
            longitude: point.longitude,
            start: workout.start,
            now: now,
            includeWeather: needsWeather,
            includeAir: needsAir
        )
        async let place = lookupPlaceIfNeeded(
            needsPlace,
            latitude: point.latitude,
            longitude: point.longitude
        )
        return Patch(conditions: await conditions, startPlace: await place)
    }

    static func weatherBases(start: Date, now: Date) -> [String] {
        let age = now.timeIntervalSince(start)
        let archive = "https://archive-api.open-meteo.com/v1/archive"
        let recent = age > -2 * 86_400 && age < 92 * 86_400
        if recent {
            return [archive, "https://api.open-meteo.com/v1/forecast"]
        }
        return [archive]
    }

    static func dayString(_ date: Date) -> String {
        shanghai("yyyy-MM-dd", date)
    }

    static func hourKey(_ date: Date) -> String {
        shanghai("yyyy-MM-dd'T'HH", date)
    }

    static func endpoint(
        _ base: String,
        latitude: Double,
        longitude: Double,
        day: String,
        hourly: String,
        extra: [URLQueryItem] = []
    ) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), longitude)),
            URLQueryItem(name: "hourly", value: hourly),
            URLQueryItem(name: "start_date", value: day),
            URLQueryItem(name: "end_date", value: day),
            URLQueryItem(name: "timezone", value: "Asia/Shanghai")
        ] + extra
        return components.url
    }

    /// Reads one Shanghai hour from Open-Meteo JSON. A neighboring hour is not used.
    static func interpret(weatherJSON: Data?, airJSON: Data?, start: Date) -> WorkoutConditions {
        var conditions = WorkoutConditions()
        let hour = hourKey(start)
        if let weatherJSON, let table = hourlyTable(weatherJSON) {
            let temperature = hit(hour, table, "temperature_2m")
            let humidity = hit(hour, table, "relative_humidity_2m")
            if case .value(let temperatureValue) = temperature, case .value(let humidityValue) = humidity {
                conditions.temperatureCelsius = finite(temperatureValue)
                conditions.relativeHumidityPercent = finite(humidityValue)
                conditions.weatherReady = true
            }
        }
        if let airJSON, let table = hourlyTable(airJSON),
           case .value(let raw) = hit(hour, table, "us_aqi") {
            conditions.airReady = true
            if let raw, raw.isFinite, raw >= 0 {
                let index = Int(raw.rounded())
                conditions.airQualityIndex = index
                let grade = Format.airQualityGrade(index)
                conditions.airQualityGrade = grade.isEmpty ? nil : grade
            }
        }
        return conditions
    }

    static func placeName(
        interest: String?,
        name: String?,
        locality: String?,
        subLocality: String?,
        thoroughfare: String?,
        subThoroughfare: String?
    ) -> String? {
        func clean(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let interest = clean(interest) { return interest }
        if let name = clean(name) { return name }
        var parts: [String] = []
        for raw in [locality, subLocality, thoroughfare, subThoroughfare] {
            guard let part = clean(raw) else { continue }
            if parts.contains(where: { $0 == part || $0.contains(part) || part.contains($0) }) { continue }
            parts.append(part)
        }
        let joined = parts.joined()
        return joined.isEmpty ? nil : joined
    }

    private static func fetchConditions(
        latitude: Double,
        longitude: Double,
        start: Date,
        now: Date,
        includeWeather: Bool,
        includeAir: Bool
    ) async -> WorkoutConditions? {
        guard includeWeather || includeAir else { return nil }
        let weatherJSON = includeWeather ? await weatherPayload(latitude: latitude, longitude: longitude, start: start, now: now) : nil
        let airJSON = includeAir ? await airPayload(latitude: latitude, longitude: longitude, start: start) : nil
        let read = interpret(weatherJSON: weatherJSON, airJSON: airJSON, start: start)
        guard read.weatherReady || read.airReady else { return nil }
        return read
    }

    private static func weatherPayload(latitude: Double, longitude: Double, start: Date, now: Date) async -> Data? {
        let day = dayString(start)
        for base in weatherBases(start: start, now: now) {
            guard let url = endpoint(
                base,
                latitude: latitude,
                longitude: longitude,
                day: day,
                hourly: "temperature_2m,relative_humidity_2m",
                extra: [URLQueryItem(name: "temperature_unit", value: "celsius")]
            ) else { continue }
            guard let data = await fetchData(url) else { continue }
            if interpret(weatherJSON: data, airJSON: nil, start: start).weatherReady {
                return data
            }
        }
        return nil
    }

    private static func airPayload(latitude: Double, longitude: Double, start: Date) async -> Data? {
        guard let url = endpoint(
            "https://air-quality-api.open-meteo.com/v1/air-quality",
            latitude: latitude,
            longitude: longitude,
            day: dayString(start),
            hourly: "us_aqi"
        ) else { return nil }
        guard let data = await fetchData(url) else { return nil }
        return interpret(weatherJSON: nil, airJSON: data, start: start).airReady ? data : nil
    }

    private static func fetchData(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("sky-wanderer", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func lookupPlaceIfNeeded(_ needed: Bool, latitude: Double, longitude: Double) async -> WorkoutStartPlace? {
        guard needed else { return nil }
        return await lookupPlace(latitude: latitude, longitude: longitude)
    }

    private static func lookupPlace(latitude: Double, longitude: Double) async -> WorkoutStartPlace? {
        #if canImport(CoreLocation)
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(
                location,
                preferredLocale: Locale(identifier: "zh_CN")
            )
            guard let mark = marks.first else { return WorkoutStartPlace(name: nil) }
            return WorkoutStartPlace(name: placeName(from: mark))
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(CoreLocation)
    private static func placeName(from placemark: CLPlacemark) -> String? {
        placeName(
            interest: placemark.areasOfInterest?.first,
            name: placemark.name,
            locality: placemark.locality,
            subLocality: placemark.subLocality,
            thoroughfare: placemark.thoroughfare,
            subThoroughfare: placemark.subThoroughfare
        )
    }
    #endif

    private static func shanghai(_ format: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private struct HourlyTable {
        var times: [String]
        var columns: [String: [Double?]]
    }

    private enum HourHit {
        case absent
        case value(Double?)
    }

    private static func hourlyTable(_ data: Data) -> HourlyTable? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["error"] as? Bool) != true,
              let hourly = object["hourly"] as? [String: Any],
              let times = hourly["time"] as? [String],
              !times.isEmpty else { return nil }
        var columns: [String: [Double?]] = [:]
        for (key, value) in hourly where key != "time" {
            guard let raw = value as? [Any] else { continue }
            columns[key] = raw.map(doubleValue)
        }
        return HourlyTable(times: times, columns: columns)
    }

    private static func hit(_ hour: String, _ table: HourlyTable, _ key: String) -> HourHit {
        guard let values = table.columns[key],
              let index = table.times.firstIndex(where: { $0.hasPrefix(hour) }),
              index < values.count else { return .absent }
        return .value(values[index])
    }

    private static func doubleValue(_ item: Any) -> Double? {
        if item is NSNull { return nil }
        if let value = item as? Double, value.isFinite { return value }
        if let value = item as? Int { return Double(value) }
        return nil
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
