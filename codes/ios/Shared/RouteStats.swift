import CoreLocation
import Foundation

struct ElevationSample: Identifiable {
    var id: Int
    var distanceKilometers: Double
    /// Meters above or below the first point. Climb is positive.
    var changeMeters: Double
}

enum RouteStats {
    static func distance(_ points: [GeoPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            total += segment(points[index - 1], points[index])
        }
        return total
    }

    static func ascent(_ points: [GeoPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var gain = 0.0
        for index in 1..<points.count {
            let delta = points[index].altitude - points[index - 1].altitude
            if delta > 0 { gain += delta }
        }
        return gain
    }

    static func maxElevation(_ points: [GeoPoint]) -> Double? {
        points.map(\.altitude).max()
    }

    /// X is distance from the start. Y is altitude change from the first point.
    static func profile(_ points: [GeoPoint]) -> [ElevationSample] {
        guard let origin = points.first else { return [] }
        var samples = [ElevationSample(id: 0, distanceKilometers: 0, changeMeters: 0)]
        var traveled = 0.0
        for index in 1..<points.count {
            traveled += segment(points[index - 1], points[index])
            samples.append(
                ElevationSample(
                    id: index,
                    distanceKilometers: traveled / 1000,
                    changeMeters: points[index].altitude - origin.altitude
                )
            )
        }
        return downsample(samples, limit: 240)
    }

    private static func segment(_ start: GeoPoint, _ end: GeoPoint) -> Double {
        let from = CLLocation(latitude: start.latitude, longitude: start.longitude)
        let to = CLLocation(latitude: end.latitude, longitude: end.longitude)
        return from.distance(from: to)
    }

    private static func downsample(_ samples: [ElevationSample], limit: Int) -> [ElevationSample] {
        guard samples.count > limit, limit >= 2 else { return samples }
        let last = samples.count - 1
        let step = Double(last) / Double(limit - 1)
        var indexes: [Int] = []
        var seen = Set<Int>()
        for slot in 0..<limit {
            let index = min(last, Int((Double(slot) * step).rounded()))
            if seen.insert(index).inserted {
                indexes.append(index)
            }
        }
        if let peak = samples.indices.max(by: { samples[$0].changeMeters < samples[$1].changeMeters }),
           seen.insert(peak).inserted {
            indexes.append(peak)
            indexes.sort()
        }
        return indexes.enumerated().map { offset, index in
            ElevationSample(
                id: offset,
                distanceKilometers: samples[index].distanceKilometers,
                changeMeters: samples[index].changeMeters
            )
        }
    }
}
