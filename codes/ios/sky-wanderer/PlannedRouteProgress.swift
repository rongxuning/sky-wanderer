import Foundation

/// Which planned polyline a workout draft is using.
/// Running and hiking share this. The sport never changes the choice.
enum TrainingRouteDraft {
    static func freeRunID() -> String {
        PlannedRoute.free.id
    }

    static func selecting(_ route: SavedRoute) -> String {
        route.id
    }

    /// An imported route wins. A saved workout id is the older fallback.
    /// `PlannedRoute.free.id` and any other unknown id are a free run: no polyline.
    static func planned(routeID: String, saved: [SavedRoute], workouts: [WorkoutRecord]) -> PlannedRoute {
        if let route = saved.first(where: { $0.id == routeID }) {
            return PlannedRoute(id: route.id, name: route.name, points: route.points)
        }
        if let workout = workouts.first(where: { $0.id.uuidString == routeID }) {
            return PlannedRoute(
                id: routeID,
                name: workout.sport.title,
                points: WorkoutTrackStore.points(for: workout)
            )
        }
        return .free
    }
}

/// Projects the athlete onto a planned route and builds that route's elevation profile.
///
/// Progress rule: project the athlete onto the planned polyline in a local
/// equirectangular plane, using the same north/east meters as `RouteStats.flatMeters`.
/// Each segment is clamped to its endpoints. The closest projection wins. When two
/// projections are equally close, the earlier one along the route stays. A vertex in
/// the middle is the same distance from either side, so it still counts as reached.
/// A closed loop repeats its start as the finish: standing there stays at the start
/// instead of snapping to the full length.
///
/// Progressed distance is the planned-path length from the start to that point.
/// Segment lengths use `RouteStats.metersBetween`, the same lengths `RouteStats.distance`
/// adds up. Remaining distance is that total minus the progressed distance.
/// It is never `max(0, plannedTotal - gpsTrackLength)`.
///
/// Off-route means the athlete is farther than `offRouteMeters` from every segment.
/// The marker still uses that closest point, so the remaining distance and the
/// elevation marker stay on the same along-track distance. A runner beside the start
/// stays at zero even if the GPS track is long. A runner beside the middle keeps
/// that along-track distance.
enum PlannedRouteProgress {
    /// Lateral distance past which the athlete is off the planned line.
    /// GPS noise inside this distance still counts as on the line.
    static let offRouteMeters = 50.0

    struct Fix: Equatable {
        var progressedMeters: Double
        var remainingMeters: Double
        var totalMeters: Double
        var offsetMeters: Double

        var offRoute: Bool { offsetMeters > PlannedRouteProgress.offRouteMeters }
        var progressedKilometers: Double { progressedMeters / 1000 }
    }

    /// Full planned profile. X is kilometers from the start. Y is altitude change from the first point.
    static func profileSamples(_ points: [GeoPoint]) -> [ElevationSample] {
        RouteStats.profile(points)
    }

    /// Axis text. Same two-decimal kilometers as `Format.kilometers`.
    static func axisLabel(distanceKilometers: Double) -> String {
        guard distanceKilometers.isFinite else { return Format.kilometers(0) }
        return Format.kilometers(max(0, distanceKilometers) * 1000)
    }

    /// Altitude change on the profile at `distanceKilometers`, interpolated between samples.
    static func changeMeters(at distanceKilometers: Double, samples: [ElevationSample]) -> Double {
        guard let first = samples.first else { return 0 }
        if !distanceKilometers.isFinite || distanceKilometers <= first.distanceKilometers {
            return first.changeMeters
        }
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let next = samples[index]
            if distanceKilometers <= next.distanceKilometers {
                let span = next.distanceKilometers - previous.distanceKilometers
                if span <= 0 { return next.changeMeters }
                let fraction = (distanceKilometers - previous.distanceKilometers) / span
                return previous.changeMeters + (next.changeMeters - previous.changeMeters) * fraction
            }
        }
        return samples.last?.changeMeters ?? first.changeMeters
    }

    static func locate(athlete: GeoPoint?, on planned: [GeoPoint]) -> Fix {
        let total = RouteStats.distance(planned)
        guard planned.count >= 2, total > 0 else {
            return Fix(progressedMeters: 0, remainingMeters: 0, totalMeters: max(0, total), offsetMeters: 0)
        }
        guard let athlete else {
            return Fix(progressedMeters: 0, remainingMeters: total, totalMeters: total, offsetMeters: 0)
        }
        var bestAlong = 0.0
        var bestOffset = Double.greatestFiniteMagnitude
        var traveled = 0.0
        for index in 1..<planned.count {
            let start = planned[index - 1]
            let end = planned[index]
            let length = RouteStats.metersBetween(start, end)
            let (fraction, offset) = fractionAlong(start, end, athlete)
            let along = traveled + length * fraction
            // Equal offsets keep the earlier point. A loop's start and finish are the same place.
            if offset < bestOffset - 0.05 {
                bestOffset = offset
                bestAlong = along
            }
            traveled += length
        }
        let progressed = min(max(0, bestAlong), total)
        let offset = bestOffset.isFinite ? max(0, bestOffset) : 0
        return Fix(
            progressedMeters: progressed,
            remainingMeters: max(0, total - progressed),
            totalMeters: total,
            offsetMeters: offset
        )
    }

    /// Clamped fraction along the segment, and the lateral offset in meters.
    private static func fractionAlong(_ start: GeoPoint, _ end: GeoPoint, _ athlete: GeoPoint) -> (Double, Double) {
        let eastSpan = east(from: start, to: end)
        let northSpan = north(from: start, to: end)
        let eastAthlete = east(from: start, to: athlete)
        let northAthlete = north(from: start, to: athlete)
        let spanSquared = eastSpan * eastSpan + northSpan * northSpan
        if spanSquared < 0.0001 {
            return (0, hypot(eastAthlete, northAthlete))
        }
        let raw = (eastAthlete * eastSpan + northAthlete * northSpan) / spanSquared
        let fraction = min(1, max(0, raw))
        let deltaEast = eastAthlete - eastSpan * fraction
        let deltaNorth = northAthlete - northSpan * fraction
        return (fraction, hypot(deltaEast, deltaNorth))
    }

    private static func north(from start: GeoPoint, to end: GeoPoint) -> Double {
        (end.latitude - start.latitude) * 111_320
    }

    private static func east(from start: GeoPoint, to end: GeoPoint) -> Double {
        let midLat = (start.latitude + end.latitude) * 0.5 * .pi / 180
        return (end.longitude - start.longitude) * 111_320 * cos(midLat)
    }
}
