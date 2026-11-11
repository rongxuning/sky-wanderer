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

    /// Absolute altitude along the path. The chart and the colored track share these altitudes.
    /// Downsampling keeps the first point, the last point, and the lowest and highest altitudes.
    static func altitudeProfile(_ points: [GeoPoint], limit: Int = 240) -> [RouteAltitudeSample] {
        guard let origin = points.first else { return [] }
        var samples = [RouteAltitudeSample(id: 0, distanceKilometers: 0, altitudeMeters: origin.altitude)]
        var traveled = 0.0
        for index in 1..<points.count {
            traveled += segment(points[index - 1], points[index])
            samples.append(
                RouteAltitudeSample(
                    id: index,
                    distanceKilometers: traveled / 1000,
                    altitudeMeters: points[index].altitude
                )
            )
        }
        return downsampleAltitude(samples, limit: limit)
    }

    private static func downsampleAltitude(_ samples: [RouteAltitudeSample], limit: Int) -> [RouteAltitudeSample] {
        guard samples.count > limit, limit >= 2 else { return samples }
        let last = samples.count - 1
        let step = Double(last) / Double(limit - 1)
        var indexes: [Int] = []
        var seen = Set<Int>()
        func add(_ index: Int) {
            if seen.insert(index).inserted {
                indexes.append(index)
            }
        }
        for slot in 0..<limit {
            add(min(last, Int((Double(slot) * step).rounded())))
        }
        if let peak = samples.indices.max(by: { samples[$0].altitudeMeters < samples[$1].altitudeMeters }) {
            add(peak)
        }
        if let trough = samples.indices.min(by: { samples[$0].altitudeMeters < samples[$1].altitudeMeters }) {
            add(trough)
        }
        indexes.sort()
        return indexes.enumerated().map { offset, index in
            RouteAltitudeSample(
                id: offset,
                distanceKilometers: samples[index].distanceKilometers,
                altitudeMeters: samples[index].altitudeMeters
            )
        }
    }
}

struct RouteAltitudeSample: Identifiable {
    var id: Int
    var distanceKilometers: Double
    var altitudeMeters: Double
}

/// Green at this route's lowest altitude, yellow in the middle, red at the highest.
struct ElevationRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let low = ElevationRGB(red: 0.18, green: 0.78, blue: 0.22)
    static let mid = ElevationRGB(red: 0.98, green: 0.84, blue: 0.08)
    static let high = ElevationRGB(red: 0.92, green: 0.18, blue: 0.14)

    func mixed(with other: ElevationRGB, fraction: Double) -> ElevationRGB {
        let t = min(1, max(0, fraction))
        return ElevationRGB(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }
}

enum ElevationScale {
    /// A route this flat has no low-to-high spread, so every point uses the middle color.
    static let flatSpanMeters = 0.5

    static func bounds(_ points: [GeoPoint]) -> (low: Double, high: Double)? {
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        var found = false
        for point in points where point.altitude.isFinite {
            found = true
            low = min(low, point.altitude)
            high = max(high, point.altitude)
        }
        guard found else { return nil }
        return (low, high)
    }

    /// 0 is this route's low altitude and 1 is its high altitude.
    static func unit(altitude: Double, low: Double, high: Double) -> Double {
        guard altitude.isFinite, low.isFinite, high.isFinite else { return 0.5 }
        let span = high - low
        guard span >= flatSpanMeters else { return 0.5 }
        return min(1, max(0, (altitude - low) / span))
    }

    static func rgb(unit: Double) -> ElevationRGB {
        let t = min(1, max(0, unit.isFinite ? unit : 0.5))
        if t == 0 { return .low }
        if t == 1 { return .high }
        if t == 0.5 { return .mid }
        if t < 0.5 {
            return ElevationRGB.low.mixed(with: .mid, fraction: t / 0.5)
        }
        return ElevationRGB.mid.mixed(with: .high, fraction: (t - 0.5) / 0.5)
    }

    static func rgb(altitude: Double, low: Double, high: Double) -> ElevationRGB {
        rgb(unit: unit(altitude: altitude, low: low, high: high))
    }
}

struct KilometerMarker: Equatable, Identifiable {
    var kilometer: Int
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var distanceMeters: Double

    var id: Int { kilometer }
}

/// Kilometer pins along the stored path. Distance is the sum of each segment, not the
/// straight line from the start to the end. A partial last kilometer has no pin.
enum RouteKilometers {
    static func markers(along points: [GeoPoint]) -> [KilometerMarker] {
        guard points.count >= 2 else { return [] }
        var markers: [KilometerMarker] = []
        var traveled = 0.0
        var nextKilometer = 1
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let length = RouteStats.metersBetween(start, end)
            guard length.isFinite, length > 0 else { continue }
            while traveled + length + 0.0001 >= Double(nextKilometer) * 1000 {
                let target = Double(nextKilometer) * 1000
                let fraction = min(1, max(0, (target - traveled) / length))
                markers.append(
                    KilometerMarker(
                        kilometer: nextKilometer,
                        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                        longitude: start.longitude + (end.longitude - start.longitude) * fraction,
                        altitude: start.altitude + (end.altitude - start.altitude) * fraction,
                        distanceMeters: target
                    )
                )
                nextKilometer += 1
                if nextKilometer > 100_000 { return markers }
            }
            traveled += length
        }
        return markers
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

/// Distance, climb, and descent from the start of the route to one real waypoint.
/// The same sums `RouteStats` uses for the whole track, stopped at the snapped point.
struct RouteWaypointProgress: Identifiable, Hashable {
    var id: Int
    var name: String
    var cutoff: String?
    /// Cumulative from the route start to the snapped track point.
    var distanceMeters: Double
    var ascentMeters: Double
    var descentMeters: Double
    /// From the previous real waypoint to this one. The first card measures from the route start.
    var segmentDistanceMeters: Double
    var segmentAscentMeters: Double
    var segmentDescentMeters: Double
    /// The waypoint's own coordinates, used to match a saved override.
    var latitude: Double
    var longitude: Double
}

/// The stretch from the last real waypoint to the track end.
/// Cumulative figures are the whole track, computed on their own, not copied from the totals card.
struct RouteFinishProgress: Hashable {
    static let title = "终点"
    var segmentDistanceMeters: Double
    var segmentAscentMeters: Double
    var segmentDescentMeters: Double
    var distanceMeters: Double
    var ascentMeters: Double
    var descentMeters: Double
}

/// One page of the route detail pager: totals, a real waypoint, or the synthetic finish.
enum RouteDetailCard: Hashable {
    case totals
    case waypoint(RouteWaypointProgress)
    case finish(RouteFinishProgress)
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

    /// One row per real waypoint, in track order. Synthetic 起点 / 终点 are not added.
    /// Cumulative figures run from the first track point to the point this waypoint snaps to.
    /// Segment figures run from the previous waypoint's snapped point. The first row uses the
    /// route start as that previous point, so its segment is start → this waypoint.
    static func progress(waypoints: [RouteWaypoint], points: [GeoPoint]) -> [RouteWaypointProgress] {
        let placed: [(offset: Int, index: Int, waypoint: RouteWaypoint)] = waypoints.enumerated().compactMap { offset, waypoint in
            guard isValid(waypoint) else { return nil }
            let index = points.isEmpty ? 0 : nearestPointIndex(waypoint, points: points)
            return (offset, index, waypoint)
        }.sorted { lhs, rhs in
            if lhs.index != rhs.index { return lhs.index < rhs.index }
            return lhs.offset < rhs.offset
        }
        let traveled = cumulative(points)
        let climbed = prefixElevation(points, loss: false)
        let dropped = prefixElevation(points, loss: true)
        return placed.enumerated().map { order, item in
            let index = traveled.indices.contains(item.index) ? item.index : 0
            let previousIndex: Int
            if order == 0 || traveled.isEmpty {
                previousIndex = 0
            } else {
                let prior = placed[order - 1].index
                previousIndex = traveled.indices.contains(prior) ? prior : 0
            }
            let lower = min(previousIndex, index)
            let upper = max(previousIndex, index)
            func at(_ values: [Double], _ position: Int) -> Double {
                guard values.indices.contains(position) else { return 0 }
                return values[position]
            }
            return RouteWaypointProgress(
                id: order,
                name: progressName(item.waypoint.name, number: order + 1),
                cutoff: progressCutoff(item.waypoint.cutoff),
                distanceMeters: at(traveled, index),
                ascentMeters: at(climbed, index),
                descentMeters: at(dropped, index),
                segmentDistanceMeters: at(traveled, upper) - at(traveled, lower),
                segmentAscentMeters: at(climbed, upper) - at(climbed, lower),
                segmentDescentMeters: at(dropped, upper) - at(dropped, lower),
                latitude: item.waypoint.latitude,
                longitude: item.waypoint.longitude
            )
        }
    }

    /// Last real waypoint → track end, when that stretch is not already the last waypoint card.
    /// Nil when there is no real waypoint, or the last one already snaps to the final track point
    /// (the same rule `layout` uses before it adds a synthetic 终点 pin).
    /// Segment figures are that last snapped point to the track end.
    /// Cumulative figures are the whole track from `RouteStats`, not the totals card.
    static func finish(waypoints: [RouteWaypoint], points: [GeoPoint]) -> RouteFinishProgress? {
        guard points.count >= 2 else { return nil }
        let rows = progress(waypoints: waypoints, points: points)
        guard let last = rows.last else { return nil }
        let drawn = layout(waypoints: waypoints, points: points)
        guard let end = drawn.marks.last, end.synthetic, end.id == "end" else { return nil }
        let distance = RouteStats.distance(points)
        let ascent = RouteStats.ascent(points)
        let descent = RouteStats.descent(points)
        return RouteFinishProgress(
            segmentDistanceMeters: distance - last.distanceMeters,
            segmentAscentMeters: ascent - last.ascentMeters,
            segmentDescentMeters: descent - last.descentMeters,
            distanceMeters: distance,
            ascentMeters: ascent,
            descentMeters: descent
        )
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

    /// Running climb or descent. Index `i` matches `RouteStats.ascent` / `descent` on `points[0...i]`.
    private static func prefixElevation(_ points: [GeoPoint], loss: Bool) -> [Double] {
        var values = Array(repeating: 0.0, count: points.count)
        guard points.count >= 2 else { return values }
        for index in 1..<points.count {
            let delta = points[index].altitude - points[index - 1].altitude
            let step = loss ? (delta < 0 ? -delta : 0) : (delta > 0 ? delta : 0)
            values[index] = values[index - 1] + step
        }
        return values
    }

    private static func progressName(_ name: String, number: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "CP\(number)" : trimmed
    }

    private static func progressCutoff(_ cutoff: String?) -> String? {
        guard let cutoff else { return nil }
        let trimmed = cutoff.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

enum RouteFactFieldChange: Equatable {
    /// The field was left blank. Drop the override and show the computed value.
    case clear
    /// Store this many meters. A value that displays the same as the computed one is not stored.
    case set(Double)
    /// Leave whatever override is already saved.
    case invalid
}

enum RouteFactTextChange: Equatable {
    case clear
    case set(String)
}

/// Resolves the route detail card. Overrides live on `SavedRoute` and never touch the GPX.
/// Segment and cumulative overrides are stored independently.
/// The synthetic 终点 card has its own override slot and is not matched like a waypoint.
enum RouteFacts {
    struct Totals: Equatable {
        var distanceMeters: Double
        var ascentMeters: Double
        var descentMeters: Double
        var maxElevationMeters: Double?
    }

    struct Waypoint: Equatable {
        var name: String
        var cutoff: String?
        var segmentDistanceMeters: Double
        var segmentAscentMeters: Double
        var segmentDescentMeters: Double
        var cumulativeDistanceMeters: Double
        var cumulativeAscentMeters: Double
        var cumulativeDescentMeters: Double
    }

    static func parseMeters(_ text: String, kilometers: Bool) -> RouteFactFieldChange {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || clearMarks.contains(trimmed) { return .clear }
        var number = trimmed.replacingOccurrences(of: "公里", with: "")
        number = number.replacingOccurrences(of: "米", with: "")
        number = number.replacingOccurrences(of: " ", with: "")
        number = number.replacingOccurrences(of: ",", with: "")
        guard let value = Double(number), value.isFinite, value >= 0 else { return .invalid }
        let meters = kilometers ? value * 1000 : value
        guard meters.isFinite else { return .invalid }
        return .set(meters)
    }

    static func parseLabel(_ text: String) -> RouteFactTextChange {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || clearMarks.contains(trimmed) { return .clear }
        return .set(trimmed)
    }

    /// Shown beside a waypoint or finish title. A blank field in the editor still clears the override.
    static let missingCutoffLabel = "暂无关门时间"

    static func cutoffLabel(_ cutoff: String?) -> String {
        let trimmed = cutoff?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? missingCutoffLabel : trimmed
    }

    /// Totals, then each real waypoint, then 终点 when the last waypoint does not land on the track end.
    static func cards(for route: SavedRoute) -> [RouteDetailCard] {
        var cards: [RouteDetailCard] = [.totals]
        let rows = RouteCheckpoints.progress(waypoints: route.waypoints, points: route.points)
        cards.append(contentsOf: rows.map { .waypoint($0) })
        if let finish = RouteCheckpoints.finish(waypoints: route.waypoints, points: route.points) {
            cards.append(.finish(finish))
        }
        return cards
    }

    static func displayTotals(_ route: SavedRoute) -> Totals {
        let totals = route.factOverrides?.totals
        return Totals(
            distanceMeters: totals?.distanceMeters ?? RouteStats.distance(route.points),
            ascentMeters: totals?.ascentMeters ?? RouteStats.ascent(route.points),
            descentMeters: totals?.descentMeters ?? RouteStats.descent(route.points),
            maxElevationMeters: totals?.maxElevationMeters ?? RouteStats.maxElevation(route.points)
        )
    }

    static func displayWaypoint(_ progress: RouteWaypointProgress, route: SavedRoute) -> Waypoint {
        let stored = storedWaypoint(route, progress: progress)
        return Waypoint(
            name: stored?.name ?? progress.name,
            cutoff: stored?.cutoff ?? progress.cutoff,
            segmentDistanceMeters: stored?.segmentDistanceMeters ?? progress.segmentDistanceMeters,
            segmentAscentMeters: stored?.segmentAscentMeters ?? progress.segmentAscentMeters,
            segmentDescentMeters: stored?.segmentDescentMeters ?? progress.segmentDescentMeters,
            cumulativeDistanceMeters: stored?.cumulativeDistanceMeters ?? progress.distanceMeters,
            cumulativeAscentMeters: stored?.cumulativeAscentMeters ?? progress.ascentMeters,
            cumulativeDescentMeters: stored?.cumulativeDescentMeters ?? progress.descentMeters
        )
    }

    /// The finish card. The title is always 终点. Numbers fall back to the track, never to the totals override.
    static func displayFinish(_ finish: RouteFinishProgress, route: SavedRoute) -> Waypoint {
        let stored = route.factOverrides?.finish
        return Waypoint(
            name: RouteFinishProgress.title,
            cutoff: stored?.cutoff,
            segmentDistanceMeters: stored?.segmentDistanceMeters ?? finish.segmentDistanceMeters,
            segmentAscentMeters: stored?.segmentAscentMeters ?? finish.segmentAscentMeters,
            segmentDescentMeters: stored?.segmentDescentMeters ?? finish.segmentDescentMeters,
            cumulativeDistanceMeters: stored?.cumulativeDistanceMeters ?? finish.distanceMeters,
            cumulativeAscentMeters: stored?.cumulativeAscentMeters ?? finish.ascentMeters,
            cumulativeDescentMeters: stored?.cumulativeDescentMeters ?? finish.descentMeters
        )
    }

    /// Pin label. A renamed card uses the override. 起点 / 终点 stay as drawn.
    static func markName(_ mark: RouteCheckpointMark, route: SavedRoute) -> String {
        guard !mark.synthetic, let overrides = route.factOverrides else { return mark.name }
        let chosen = overrides.waypoints.first {
            $0.sourceName == mark.name && close($0, latitude: mark.latitude, longitude: mark.longitude)
        }
        if let name = chosen?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return mark.name
    }

    static func applyTotals(
        _ route: inout SavedRoute,
        distance: RouteFactFieldChange,
        ascent: RouteFactFieldChange,
        descent: RouteFactFieldChange,
        maxElevation: RouteFactFieldChange
    ) {
        var overrides = route.factOverrides ?? RouteFactOverrides()
        var totals = overrides.totals ?? RouteTotalOverrides()
        assign(distance, computed: RouteStats.distance(route.points), kilometers: true, to: &totals.distanceMeters)
        assign(ascent, computed: RouteStats.ascent(route.points), kilometers: false, to: &totals.ascentMeters)
        assign(descent, computed: RouteStats.descent(route.points), kilometers: false, to: &totals.descentMeters)
        assign(maxElevation, computed: RouteStats.maxElevation(route.points), kilometers: false, to: &totals.maxElevationMeters)
        overrides.totals = totals
        commit(overrides, to: &route)
    }

    /// Writes one card. A segment change does not rewrite the cumulative fields, and the reverse.
    /// `.invalid` keeps the stored override for that field. `.clear` deletes it.
    static func applyWaypoint(
        _ route: inout SavedRoute,
        progress: RouteWaypointProgress,
        name: RouteFactTextChange,
        cutoff: RouteFactTextChange,
        segmentDistance: RouteFactFieldChange,
        segmentAscent: RouteFactFieldChange,
        segmentDescent: RouteFactFieldChange,
        cumulativeDistance: RouteFactFieldChange,
        cumulativeAscent: RouteFactFieldChange,
        cumulativeDescent: RouteFactFieldChange
    ) {
        var overrides = route.factOverrides ?? RouteFactOverrides()
        var row: RouteWaypointFactOverride
        let existingIndex = waypointIndex(overrides, progress: progress)
        if let existingIndex {
            row = overrides.waypoints[existingIndex]
        } else {
            row = RouteWaypointFactOverride(
                latitude: progress.latitude,
                longitude: progress.longitude,
                sourceName: progress.name
            )
        }
        assign(name, computed: progress.name, to: &row.name)
        assign(cutoff, computed: progress.cutoff, to: &row.cutoff)
        assign(segmentDistance, computed: progress.segmentDistanceMeters, kilometers: true, to: &row.segmentDistanceMeters)
        assign(segmentAscent, computed: progress.segmentAscentMeters, kilometers: false, to: &row.segmentAscentMeters)
        assign(segmentDescent, computed: progress.segmentDescentMeters, kilometers: false, to: &row.segmentDescentMeters)
        assign(cumulativeDistance, computed: progress.distanceMeters, kilometers: true, to: &row.cumulativeDistanceMeters)
        assign(cumulativeAscent, computed: progress.ascentMeters, kilometers: false, to: &row.cumulativeAscentMeters)
        assign(cumulativeDescent, computed: progress.descentMeters, kilometers: false, to: &row.cumulativeDescentMeters)
        if let existingIndex {
            overrides.waypoints[existingIndex] = row
        } else if !row.isEmpty {
            overrides.waypoints.append(row)
        }
        commit(overrides, to: &route)
    }

    /// Writes the synthetic 终点 card. Does nothing when that card is not shown.
    /// A segment change does not rewrite the cumulative fields, and neither field touches totals or waypoints.
    static func applyFinish(
        _ route: inout SavedRoute,
        cutoff: RouteFactTextChange,
        segmentDistance: RouteFactFieldChange,
        segmentAscent: RouteFactFieldChange,
        segmentDescent: RouteFactFieldChange,
        cumulativeDistance: RouteFactFieldChange,
        cumulativeAscent: RouteFactFieldChange,
        cumulativeDescent: RouteFactFieldChange
    ) {
        guard let finish = RouteCheckpoints.finish(waypoints: route.waypoints, points: route.points) else { return }
        var overrides = route.factOverrides ?? RouteFactOverrides()
        var row = overrides.finish ?? RouteFinishFactOverride()
        assign(cutoff, computed: nil, to: &row.cutoff)
        assign(segmentDistance, computed: finish.segmentDistanceMeters, kilometers: true, to: &row.segmentDistanceMeters)
        assign(segmentAscent, computed: finish.segmentAscentMeters, kilometers: false, to: &row.segmentAscentMeters)
        assign(segmentDescent, computed: finish.segmentDescentMeters, kilometers: false, to: &row.segmentDescentMeters)
        assign(cumulativeDistance, computed: finish.distanceMeters, kilometers: true, to: &row.cumulativeDistanceMeters)
        assign(cumulativeAscent, computed: finish.ascentMeters, kilometers: false, to: &row.cumulativeAscentMeters)
        assign(cumulativeDescent, computed: finish.descentMeters, kilometers: false, to: &row.cumulativeDescentMeters)
        overrides.finish = row
        commit(overrides, to: &route)
    }

    private static let clearMarks: Set<String> = ["—", "–", "-", "－", "―"]

    /// Same rounding the card uses: kilometers to two decimals, elevations to the nearest meter.
    private static func sameDisplayed(_ value: Double, _ computed: Double, kilometers: Bool) -> Bool {
        if kilometers {
            return String(format: "%.2f", value / 1000) == String(format: "%.2f", computed / 1000)
        }
        return Int(value.rounded()) == Int(computed.rounded())
    }

    private static func assign(
        _ change: RouteFactFieldChange,
        computed: Double?,
        kilometers: Bool,
        to slot: inout Double?
    ) {
        switch change {
        case .invalid:
            return
        case .clear:
            slot = nil
        case .set(let value):
            if let computed, sameDisplayed(value, computed, kilometers: kilometers) {
                slot = nil
            } else {
                slot = value
            }
        }
    }

    private static func assign(
        _ change: RouteFactTextChange,
        computed: String?,
        to slot: inout String?
    ) {
        switch change {
        case .clear:
            slot = nil
        case .set(let text):
            slot = text == computed ? nil : text
        }
    }

    private static func storedWaypoint(
        _ route: SavedRoute,
        progress: RouteWaypointProgress
    ) -> RouteWaypointFactOverride? {
        guard let overrides = route.factOverrides,
              let index = waypointIndex(overrides, progress: progress) else { return nil }
        return overrides.waypoints[index]
    }

    private static func waypointIndex(
        _ overrides: RouteFactOverrides,
        progress: RouteWaypointProgress
    ) -> Int? {
        overrides.waypoints.indices.first { index in
            let item = overrides.waypoints[index]
            return item.sourceName == progress.name && close(item, latitude: progress.latitude, longitude: progress.longitude)
        }
    }

    private static func close(
        _ override: RouteWaypointFactOverride,
        latitude: Double,
        longitude: Double
    ) -> Bool {
        abs(override.latitude - latitude) < 0.0001 && abs(override.longitude - longitude) < 0.0001
    }

    private static func commit(_ overrides: RouteFactOverrides, to route: inout SavedRoute) {
        var copy = overrides
        copy.waypoints.removeAll { $0.isEmpty }
        if copy.totals?.isEmpty == true {
            copy.totals = nil
        }
        if copy.finish?.isEmpty == true {
            copy.finish = nil
        }
        route.factOverrides = copy.isEmpty ? nil : copy
    }
}

struct ElevationAxisMark: Equatable, Identifiable {
    var id: String
    /// Cumulative kilometers from `Format.kilometers`, with no unit suffix.
    var name: String
    var distanceMeters: Double
    var fraction: Double
}

struct ElevationAxisLabel: Equatable, Identifiable {
    var id: String
    var name: String
    /// Where the tick is drawn, along the distance axis. This stays on the waypoint.
    var tickFraction: Double
    /// Where the short label is drawn. It may shift a little so neighbors stay readable.
    var labelFraction: Double
    var lane: Int
}

/// Checkpoint ticks for the elevation profile, in track order.
/// Real waypoints keep their snapped distances. A synthetic finish tick is added at the
/// track end when a finish card exists. The text under a tick is that distance in
/// kilometers (`Format.kilometers`), with no 「公里」 suffix — the axis already prints
/// 0 on the left and the total on the right. A mark whose two-decimal label would
/// repeat either of those is omitted, tick included. Intermediate checkpoints stay.
enum ElevationProfileAxis {
    static func marks(for route: SavedRoute) -> [ElevationAxisMark] {
        let points = route.points
        let total = RouteStats.distance(points)
        let rows = RouteCheckpoints.progress(waypoints: route.waypoints, points: points)
        var marks = rows.map { row in
            kilometerMark(id: "w\(row.id)", distanceMeters: row.distanceMeters, total: total)
        }
        if RouteCheckpoints.finish(waypoints: route.waypoints, points: points) != nil {
            marks.append(kilometerMark(id: "finish", distanceMeters: total, total: total))
        }
        let endpointLabels = [Format.kilometers(0), Format.kilometers(total)]
        return marks.filter { !endpointLabels.contains($0.name) }
    }

    private static func kilometerMark(id: String, distanceMeters: Double, total: Double) -> ElevationAxisMark {
        ElevationAxisMark(
            id: id,
            name: Format.kilometers(distanceMeters),
            distanceMeters: distanceMeters,
            fraction: fraction(distanceMeters, total: total)
        )
    }

    /// Every mark keeps its tick. Labels nudge a few points, then step down a lane, rather than disappearing.
    static func labels(
        _ marks: [ElevationAxisMark],
        plotWidth: Double,
        labelWidth: (String) -> Double,
        gap: Double = 3
    ) -> [ElevationAxisLabel] {
        func make(_ mark: ElevationAxisMark, center: Double, lane: Int) -> ElevationAxisLabel {
            let fraction = plotWidth > 1 ? center / plotWidth : mark.fraction
            return ElevationAxisLabel(
                id: mark.id,
                name: mark.name,
                tickFraction: mark.fraction,
                labelFraction: min(1, max(0, fraction)),
                lane: lane
            )
        }
        guard plotWidth > 1 else {
            return marks.map { make($0, center: 0, lane: 0) }
        }
        var boxes: [(lane: Int, lo: Double, hi: Double)] = []
        var placed: [ElevationAxisLabel] = []
        let shiftLimit = 28.0
        let shiftStep = 4.0
        for mark in marks {
            let width = min(max(labelWidth(mark.name), 8), plotWidth)
            let half = width / 2
            let tickX = min(max(mark.fraction, 0), 1) * plotWidth
            var resolved: (center: Double, lane: Int)?
            let laneLimit = max(marks.count, 1)
            search: for lane in 0..<laneLimit {
                var shift = 0.0
                while shift <= shiftLimit {
                    let deltas: [Double] = shift == 0 ? [0] : [shift, -shift]
                    for delta in deltas {
                        let center = min(max(tickX + delta, half), plotWidth - half)
                        let lo = center - half
                        let hi = center + half
                        let blocked = boxes.contains { box in
                            box.lane == lane && hi + gap > box.lo && lo < box.hi + gap
                        }
                        if !blocked {
                            resolved = (center, lane)
                            break search
                        }
                    }
                    shift += shiftStep
                }
            }
            let choice = resolved ?? (
                min(max(tickX, half), plotWidth - half),
                (boxes.map(\.lane).max() ?? -1) + 1
            )
            boxes.append((choice.lane, choice.center - half, choice.center + half))
            placed.append(make(mark, center: choice.center, lane: choice.lane))
        }
        return placed
    }

    private static func fraction(_ distance: Double, total: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, distance / total))
    }
}
