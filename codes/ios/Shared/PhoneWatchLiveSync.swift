import Foundation

/// Phone → Watch live workout snapshot. Kept small for WatchConnectivity.
struct PhoneWatchLiveSnapshot: Codable, Equatable {
    static let contextKey = "sky.live.v1"
    static let version = 1

    var version: Int
    var active: Bool
    var sportRaw: String
    var elapsed: TimeInterval
    var distanceMeters: Double
    var paceSecPerKm: Double
    var heartRate: Double
    var cadence: Double
    var altitudeMeters: Double
    var paused: Bool
    var latitude: Double?
    var longitude: Double?
    var route: [PhoneWatchCoord]
    var kilometers: [PhoneWatchKilometer]

    var sport: SportKind {
        SportKind(rawValue: sportRaw) ?? .running
    }

    var userFix: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(
            latitude: latitude,
            longitude: longitude,
            altitude: altitudeMeters,
            timestamp: nil
        )
    }

    var routePoints: [GeoPoint] {
        route.map {
            GeoPoint(latitude: $0.lat, longitude: $0.lon, altitude: $0.alt, timestamp: nil)
        }
    }

    var kilometerMarks: [KilometerMarker] {
        kilometers.map {
            KilometerMarker(
                kilometer: $0.km,
                latitude: $0.lat,
                longitude: $0.lon,
                altitude: $0.alt,
                distanceMeters: Double($0.km) * 1000
            )
        }
    }

    static func idle() -> PhoneWatchLiveSnapshot {
        PhoneWatchLiveSnapshot(
            version: version,
            active: false,
            sportRaw: SportKind.running.rawValue,
            elapsed: 0,
            distanceMeters: 0,
            paceSecPerKm: 0,
            heartRate: 0,
            cadence: 0,
            altitudeMeters: 0,
            paused: false,
            latitude: nil,
            longitude: nil,
            route: [],
            kilometers: []
        )
    }

    static func from(
        sport: SportKind,
        elapsed: TimeInterval,
        distanceMeters: Double,
        paceSecPerKm: Double,
        heartRate: Double,
        cadence: Double,
        altitudeMeters: Double,
        paused: Bool,
        userFix: GeoPoint?,
        route: [GeoPoint],
        kilometers: [KilometerMarker],
        routeLimit: Int = 80
    ) -> PhoneWatchLiveSnapshot {
        PhoneWatchLiveSnapshot(
            version: version,
            active: true,
            sportRaw: sport.rawValue,
            elapsed: elapsed,
            distanceMeters: distanceMeters,
            paceSecPerKm: paceSecPerKm,
            heartRate: heartRate,
            cadence: cadence,
            altitudeMeters: altitudeMeters,
            paused: paused,
            latitude: userFix?.latitude,
            longitude: userFix?.longitude,
            route: compactRoute(route, limit: routeLimit),
            kilometers: kilometers.map {
                PhoneWatchKilometer(km: $0.kilometer, lat: $0.latitude, lon: $0.longitude, alt: $0.altitude)
            }
        )
    }

    /// Evenly samples the track so the watch payload stays under the context size limit.
    static func compactRoute(_ points: [GeoPoint], limit: Int) -> [PhoneWatchCoord] {
        guard limit > 1, points.count > limit else {
            return points.map { PhoneWatchCoord(lat: $0.latitude, lon: $0.longitude, alt: $0.altitude) }
        }
        let lastIndex = points.count - 1
        return (0..<limit).map { slot in
            let index = Int((Double(slot) * Double(lastIndex) / Double(limit - 1)).rounded())
            let point = points[index]
            return PhoneWatchCoord(lat: point.latitude, lon: point.longitude, alt: point.altitude)
        }
    }

    func dictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        return [Self.contextKey: data]
    }

    static func decode(from dictionary: [String: Any]) -> PhoneWatchLiveSnapshot? {
        guard let data = dictionary[contextKey] as? Data else { return nil }
        return try? JSONDecoder().decode(PhoneWatchLiveSnapshot.self, from: data)
    }
}

struct PhoneWatchCoord: Codable, Equatable {
    var lat: Double
    var lon: Double
    var alt: Double
}

struct PhoneWatchKilometer: Codable, Equatable {
    var km: Int
    var lat: Double
    var lon: Double
    var alt: Double
}

/// Phone LiveSession pushes here. The watch target leaves the sink nil.
@MainActor
protocol PhoneWatchLiveSink: AnyObject {
    func pushLive(_ snapshot: PhoneWatchLiveSnapshot)
    func endLive()
}
