import CoreLocation
import Foundation

/// Official sunrise and sunset for a latitude and longitude.
/// Zenith 90.833° includes atmospheric refraction. The math is the NOAA solar calculator.
enum SolarClock {
    /// Shanghai, used when Core Location is denied or still waiting.
    static let shanghaiLatitude = 31.2304
    static let shanghaiLongitude = 121.4737

    private static let zenith = 90.833

    static func isDaylight(
        at date: Date,
        latitude: Double,
        longitude: Double,
        timeZone: TimeZone = .current
    ) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return true
        }
        if let sunrise = event(
            year: year,
            month: month,
            day: day,
            latitude: latitude,
            longitude: longitude,
            sunrise: true
        ),
           let sunset = event(
            year: year,
            month: month,
            day: day,
            latitude: latitude,
            longitude: longitude,
            sunrise: false
           ),
           sunset > sunrise {
            return date >= sunrise && date < sunset
        }
        return elevation(at: date, latitude: latitude, longitude: longitude) >= -0.833
    }

    private static func event(
        year: Int,
        month: Int,
        day: Int,
        latitude: Double,
        longitude: Double,
        sunrise: Bool
    ) -> Date? {
        let jd = julianDay(year: year, month: month, day: day)
        guard let first = utcMinutes(
            sunrise: sunrise,
            julianDay: jd,
            latitude: latitude,
            longitude: longitude
        ) else {
            return nil
        }
        let refined = utcMinutes(
            sunrise: sunrise,
            julianDay: jd + first / 1440,
            latitude: latitude,
            longitude: longitude
        ) ?? first
        return utcDate(year: year, month: month, day: day, minutes: refined)
    }

    private static func utcDate(year: Int, month: Int, day: Int, minutes: Double) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.timeZone = utc
        guard let midnight = calendar.date(from: DateComponents(
            timeZone: utc,
            year: year,
            month: month,
            day: day
        )) else {
            return nil
        }
        return midnight.addingTimeInterval(minutes * 60)
    }

    /// Minutes from 00:00 UTC. Negative and past-24h values are left intact so `Date` can roll the day.
    private static func utcMinutes(
        sunrise: Bool,
        julianDay jd: Double,
        latitude: Double,
        longitude: Double
    ) -> Double? {
        let t = julianCentury(jd)
        let eqTime = equationOfTime(t)
        let declination = sunDeclination(t)
        let latitudeRadians = latitude * .pi / 180
        let declinationRadians = declination * .pi / 180
        let denominator = cos(latitudeRadians) * cos(declinationRadians)
        if abs(denominator) < 1e-6 { return nil }
        let cosHour = cos(zenith * .pi / 180) / denominator - tan(latitudeRadians) * tan(declinationRadians)
        if cosHour > 1 || cosHour < -1 { return nil }
        let hourAngle = acos(cosHour)
        let signed = sunrise ? hourAngle : -hourAngle
        let delta = longitude + signed * 180 / .pi
        return 720 - (4 * delta) - eqTime
    }

    private static func elevation(at date: Date, latitude: Double, longitude: Double) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.timeZone = utc
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return -90 }
        let minutes = Double(parts.hour ?? 0) * 60
            + Double(parts.minute ?? 0)
            + Double(parts.second ?? 0) / 60
        let t = julianCentury(julianDay(year: year, month: month, day: day) + minutes / 1440)
        var trueSolar = minutes + equationOfTime(t) + 4 * longitude
        trueSolar = trueSolar.truncatingRemainder(dividingBy: 1440)
        if trueSolar < 0 { trueSolar += 1440 }
        let hourAngle = (trueSolar / 4 - 180) * .pi / 180
        let latitudeRadians = latitude * .pi / 180
        let declinationRadians = sunDeclination(t) * .pi / 180
        let sine = sin(latitudeRadians) * sin(declinationRadians)
            + cos(latitudeRadians) * cos(declinationRadians) * cos(hourAngle)
        return asin(min(1, max(-1, sine))) * 180 / .pi
    }

    private static func julianCentury(_ jd: Double) -> Double {
        (jd - 2451545.0) / 36525.0
    }

    private static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var year = year
        var month = month
        if month <= 2 {
            year -= 1
            month += 12
        }
        let a = floor(Double(year) / 100)
        let b = 2 - a + floor(a / 4)
        return floor(365.25 * Double(year + 4716))
            + floor(30.6001 * Double(month + 1))
            + Double(day) + b - 1524.5
    }

    private static func wrap360(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    private static func geomMeanLongSun(_ t: Double) -> Double {
        wrap360(280.46646 + t * (36000.76983 + t * 0.0003032))
    }

    private static func geomMeanAnomalySun(_ t: Double) -> Double {
        357.52911 + t * (35999.05029 - 0.0001537 * t)
    }

    private static func eccentricity(_ t: Double) -> Double {
        0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    }

    private static func sunEqOfCenter(_ t: Double) -> Double {
        let anomaly = geomMeanAnomalySun(t) * .pi / 180
        return sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * anomaly) * (0.019993 - 0.000101 * t)
            + sin(3 * anomaly) * 0.000289
    }

    private static func sunApparentLong(_ t: Double) -> Double {
        let omega = 125.04 - 1934.136 * t
        return geomMeanLongSun(t) + sunEqOfCenter(t) - 0.00569 - 0.00478 * sin(omega * .pi / 180)
    }

    private static func meanObliquity(_ t: Double) -> Double {
        let seconds = 21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813))
        return 23 + (26 + (seconds / 60)) / 60
    }

    private static func obliquityCorrection(_ t: Double) -> Double {
        let omega = 125.04 - 1934.136 * t
        return meanObliquity(t) + 0.00256 * cos(omega * .pi / 180)
    }

    private static func sunDeclination(_ t: Double) -> Double {
        let obliquity = obliquityCorrection(t) * .pi / 180
        let longitude = sunApparentLong(t) * .pi / 180
        return asin(sin(obliquity) * sin(longitude)) * 180 / .pi
    }

    private static func equationOfTime(_ t: Double) -> Double {
        let epsilon = obliquityCorrection(t) * .pi / 180
        let meanLongitude = geomMeanLongSun(t) * .pi / 180
        let orbit = eccentricity(t)
        let anomaly = geomMeanAnomalySun(t) * .pi / 180
        let y = tan(epsilon / 2)
        let y2 = y * y
        let eTime = y2 * sin(2 * meanLongitude)
            - 2 * orbit * sin(anomaly)
            + 4 * orbit * y2 * sin(anomaly) * cos(2 * meanLongitude)
            - 0.5 * y2 * y2 * sin(4 * meanLongitude)
            - 1.25 * orbit * orbit * sin(2 * anomaly)
        return eTime * 180 / .pi * 4
    }
}

/// One-shot location for sunrise and sunset. Denied or failed fixes stay on Shanghai.
final class SolarLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate = CLLocationCoordinate2D(
        latitude: SolarClock.shanghaiLatitude,
        longitude: SolarClock.shanghaiLongitude
    )
    @Published private(set) var usingFallback = true

    private let manager = CLLocationManager()
    private var hasFix = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            applyAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        applyAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        coordinate = location.coordinate
        usingFallback = false
        hasFix = true
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError _: Error) {
        if !hasFix {
            useFallback()
        }
    }

    private func applyAuthorization() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            useFallback()
        case .notDetermined:
            break
        @unknown default:
            useFallback()
        }
    }

    private func useFallback() {
        coordinate = CLLocationCoordinate2D(
            latitude: SolarClock.shanghaiLatitude,
            longitude: SolarClock.shanghaiLongitude
        )
        usingFallback = true
    }
}
