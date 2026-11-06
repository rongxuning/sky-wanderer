#if canImport(CoreLocation)
import CoreLocation
#endif
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

    /// Meters of elevation lost. The same step rule as `ascent`, in the other direction.
    static func descent(_ points: [GeoPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var loss = 0.0
        for index in 1..<points.count {
            let delta = points[index].altitude - points[index - 1].altitude
            if delta < 0 { loss -= delta }
        }
        return loss
    }

    static func metersBetween(_ start: GeoPoint, _ end: GeoPoint) -> Double {
        segment(start, end)
    }

    /// Equirectangular meters. Used to pick a nearest track point, not to publish distance.
    static func flatMeters(_ start: GeoPoint, _ end: GeoPoint) -> Double {
        let midLat = (start.latitude + end.latitude) * 0.5 * .pi / 180
        let north = (end.latitude - start.latitude) * 111_320
        let east = (end.longitude - start.longitude) * 111_320 * cos(midLat)
        return (north * north + east * east).squareRoot()
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
        #if canImport(CoreLocation)
        let from = CLLocation(latitude: start.latitude, longitude: start.longitude)
        let to = CLLocation(latitude: end.latitude, longitude: end.longitude)
        return from.distance(from: to)
        #else
        return flatMeters(start, end)
        #endif
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

struct RouteCheckpointMark: Identifiable, Hashable {
    var id: String
    var name: String
    /// Where the pin is drawn. A real waypoint keeps its own coordinates.
    var latitude: Double
    var longitude: Double
    /// Distance from the start to the snapped track point.
    var distanceMeters: Double
    /// Altitude change of the snapped track point from the first point.
    var changeMeters: Double
    var snappedIndex: Int
    /// 起点 or 终点 added for segment math when that end is not already a waypoint.
    var synthetic: Bool

    var distanceKilometers: Double { distanceMeters / 1000 }
}

struct RouteSegmentSummary: Identifiable, Hashable {
    var id: Int
    var title: String
    var distanceMeters: Double
    var ascentMeters: Double
    var descentMeters: Double
}

struct RouteCheckpointLayout: Hashable {
    var marks: [RouteCheckpointMark]
    var segments: [RouteSegmentSummary]

    static let empty = RouteCheckpointLayout(marks: [], segments: [])
}

/// Places GPX checkpoints on a track and splits the line into 起点 / CP / 终点 segments.
enum RouteCheckpoints {
    /// Route order. Empty names become CP1, CP2, skipping labels the file already used.
    static func ordered(_ waypoints: [RouteWaypoint], along points: [GeoPoint]) -> [RouteWaypoint] {
        let usable = waypoints.filter(isValid)
        let ranked: [(index: Int, offset: Int, waypoint: RouteWaypoint)]
        if points.count >= 2 {
            ranked = usable.enumerated().map { offset, waypoint in
                (index: nearestPointIndex(waypoint, points: points), offset: offset, waypoint: waypoint)
            }.sorted { lhs, rhs in
                if lhs.index != rhs.index { return lhs.index < rhs.index }
                return lhs.offset < rhs.offset
            }
        } else {
            ranked = usable.enumerated().map { offset, waypoint in
                (index: offset, offset: offset, waypoint: waypoint)
            }
        }
        var used = Set(ranked.map { $0.waypoint.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        var number = 1
        return ranked.map { item in
            let waypoint = item.waypoint
            var copy = waypoint
            let trimmed = waypoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                var candidate = "CP\(number)"
                number += 1
                while used.contains(candidate) {
                    candidate = "CP\(number)"
                    number += 1
                }
                used.insert(candidate)
                copy.name = candidate
            } else {
                copy.name = trimmed
            }
            return copy
        }
    }

    /// Real checkpoints, plus 起点 / 终点 when those ends are not already waypoints.
    /// No marks at all when the route has no checkpoints.
    static func layout(waypoints: [RouteWaypoint], points: [GeoPoint]) -> RouteCheckpointLayout {
        let key = memoKey(waypoints: waypoints, points: points)
        if let memo, memo.key == key { return memo.layout }
        let built = build(waypoints: waypoints, points: points)
        memo = Memo(key: key, layout: built)
        return built
    }

    private struct Memo {
        var key: Int
        var layout: RouteCheckpointLayout
    }

    private static var memo: Memo?

    private static func build(waypoints: [RouteWaypoint], points: [GeoPoint]) -> RouteCheckpointLayout {
        guard points.count >= 2 else { return .empty }
        let traveled = cumulative(points)
        let origin = points[0].altitude
        let placed: [(offset: Int, mark: RouteCheckpointMark)] = waypoints.enumerated().compactMap { offset, waypoint in
            guard isValid(waypoint) else { return nil }
            let index = nearestPointIndex(waypoint, points: points)
            let name = waypoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let change = points[index].altitude - origin
            let mark = RouteCheckpointMark(
                id: "w\(offset)",
                name: name,
                latitude: waypoint.latitude,
                longitude: waypoint.longitude,
                distanceMeters: traveled[index],
                changeMeters: change.isFinite ? change : 0,
                snappedIndex: index,
                synthetic: false
            )
            return (offset: offset, mark: mark)
        }
        var real: [RouteCheckpointMark] = placed.sorted { lhs, rhs in
            if lhs.mark.snappedIndex != rhs.mark.snappedIndex { return lhs.mark.snappedIndex < rhs.mark.snappedIndex }
            return lhs.offset < rhs.offset
        }.map(\.mark)
        guard !real.isEmpty else { return .empty }
        real = fallbackNames(real)
        if real[0].snappedIndex != 0 {
            real.insert(endpoint(name: "起点", point: points[0], index: 0, traveled: traveled, origin: origin, id: "start"), at: 0)
        }
        let last = points.count - 1
        if real[real.count - 1].snappedIndex != last {
            real.append(endpoint(name: "终点", point: points[last], index: last, traveled: traveled, origin: origin, id: "end"))
        }
        return RouteCheckpointLayout(marks: real, segments: segments(marks: real, points: points))
    }

    static func nearestPointIndex(_ waypoint: RouteWaypoint, points: [GeoPoint]) -> Int {
        guard !points.isEmpty else { return 0 }
        let probe = GeoPoint(latitude: waypoint.latitude, longitude: waypoint.longitude, altitude: 0, timestamp: nil)
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, point) in points.enumerated() {
            let distance = RouteStats.flatMeters(probe, point)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private static func endpoint(
        name: String,
        point: GeoPoint,
        index: Int,
        traveled: [Double],
        origin: Double,
        id: String
    ) -> RouteCheckpointMark {
        let change = point.altitude - origin
        return RouteCheckpointMark(
            id: id,
            name: name,
            latitude: point.latitude,
            longitude: point.longitude,
            distanceMeters: traveled[index],
            changeMeters: change.isFinite ? change : 0,
            snappedIndex: index,
            synthetic: true
        )
    }

    private static func fallbackNames(_ marks: [RouteCheckpointMark]) -> [RouteCheckpointMark] {
        var used = Set(marks.map(\.name).filter { !$0.isEmpty })
        var number = 1
        return marks.map { mark in
            guard mark.name.isEmpty else { return mark }
            var copy = mark
            var candidate = "CP\(number)"
            number += 1
            while used.contains(candidate) {
                candidate = "CP\(number)"
                number += 1
            }
            used.insert(candidate)
            copy.name = candidate
            return copy
        }
    }

    private static func segments(marks: [RouteCheckpointMark], points: [GeoPoint]) -> [RouteSegmentSummary] {
        guard marks.count >= 2 else { return [] }
        var rows: [RouteSegmentSummary] = []
        for index in 1..<marks.count {
            let start = marks[index - 1].snappedIndex
            let end = marks[index].snappedIndex
            let lower = min(start, end)
            let upper = max(start, end)
            let slice = Array(points[lower...upper])
            rows.append(
                RouteSegmentSummary(
                    id: index - 1,
                    title: "\(marks[index - 1].name)→\(marks[index].name)",
                    distanceMeters: RouteStats.distance(slice),
                    ascentMeters: RouteStats.ascent(slice),
                    descentMeters: RouteStats.descent(slice)
                )
            )
        }
        return rows
    }

    private static func cumulative(_ points: [GeoPoint]) -> [Double] {
        var values = Array(repeating: 0.0, count: points.count)
        guard points.count >= 2 else { return values }
        for index in 1..<points.count {
            values[index] = values[index - 1] + RouteStats.metersBetween(points[index - 1], points[index])
        }
        return values
    }

    private static func isValid(_ waypoint: RouteWaypoint) -> Bool {
        waypoint.latitude.isFinite && waypoint.longitude.isFinite
            && abs(waypoint.latitude) <= 90 && abs(waypoint.longitude) <= 180
    }

    private static func memoKey(waypoints: [RouteWaypoint], points: [GeoPoint]) -> Int {
        var hasher = Hasher()
        hasher.combine(points.count)
        hasher.combine(waypoints.count)
        let step = max(points.count / 16, 1)
        var index = 0
        while index < points.count {
            hasher.combine(points[index].latitude)
            hasher.combine(points[index].longitude)
            hasher.combine(points[index].altitude)
            index += step
        }
        for waypoint in waypoints {
            hasher.combine(waypoint.name)
            hasher.combine(waypoint.latitude)
            hasher.combine(waypoint.longitude)
            hasher.combine(waypoint.elevation)
        }
        return hasher.finalize()
    }
}
