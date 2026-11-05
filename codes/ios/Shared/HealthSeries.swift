import Foundation

/// One Health quantity sample reduced to a time window and a unit-converted value.
struct HealthQuantitySample: Equatable {
    var start: Date
    var end: Date
    var value: Double
}

/// Series stored on an imported workout.
/// `SeriesPoint.second` is seconds after the workout start.
/// Cadence comes from step-count windows: HealthKit has no running-cadence identifier.
/// Ground contact is stored in milliseconds. Vertical oscillation is stored in millimeters.
enum HealthSeries {
    static let maxPoints = 720

    static func instantaneous(
        _ samples: [HealthQuantitySample],
        workoutStart: Date,
        workoutEnd: Date,
        convert: (Double) -> Double = { $0 }
    ) -> [SeriesPoint] {
        let points = samples.compactMap { sample -> SeriesPoint? in
            guard sample.end >= workoutStart, sample.start <= workoutEnd else { return nil }
            let value = convert(sample.value)
            guard value.isFinite, value > 0 else { return nil }
            return SeriesPoint(second: second(sample.end, start: workoutStart, end: workoutEnd), value: value)
        }
        return capped(points)
    }

    /// HealthKit reports running ground-contact time in seconds.
    static func groundContactMilliseconds(
        _ samples: [HealthQuantitySample],
        workoutStart: Date,
        workoutEnd: Date
    ) -> [SeriesPoint] {
        instantaneous(samples, workoutStart: workoutStart, workoutEnd: workoutEnd) { $0 * 1000 }
    }

    /// HealthKit reports running vertical oscillation as a length. Samples are meters.
    static func verticalOscillationMillimeters(
        _ samples: [HealthQuantitySample],
        workoutStart: Date,
        workoutEnd: Date
    ) -> [SeriesPoint] {
        instantaneous(samples, workoutStart: workoutStart, workoutEnd: workoutEnd) { $0 * 1000 }
    }

    /// Steps in each sample window, as steps per minute. Windows outside a walking band are dropped.
    static func cadence(
        stepSamples: [HealthQuantitySample],
        workoutStart: Date,
        workoutEnd: Date
    ) -> [SeriesPoint] {
        let points = stepSamples.compactMap { sample -> SeriesPoint? in
            guard sample.end >= workoutStart, sample.start <= workoutEnd else { return nil }
            let duration = sample.end.timeIntervalSince(sample.start)
            let stepsPerMinute = CadenceMath.stepsPerMinute(steps: sample.value, duration: duration)
            guard stepsPerMinute > 0 else { return nil }
            return SeriesPoint(
                second: second(sample.end, start: workoutStart, end: workoutEnd),
                value: stepsPerMinute
            )
        }
        return capped(points)
    }

    struct Track: Equatable {
        var pace: [SeriesPoint]
        var splits: [KilometerSplit]
        var elevation: [SeriesPoint]
    }

    /// Pace and splits prefer a timestamped route. Distance samples are the fallback.
    /// Elevation always comes from route altitudes.
    static func track(
        route: [GeoPoint],
        distanceSamples: [HealthQuantitySample],
        workoutStart: Date,
        workoutEnd: Date,
        referenceDistanceMeters: Double,
        heartRate: [SeriesPoint],
        cadence: [SeriesPoint]
    ) -> Track {
        let followed = routeTimeline(route, workoutStart: workoutStart, workoutEnd: workoutEnd)
        let routeMeters = followed.last?.meters ?? 0
        let movement: [TimedDistance]
        if followed.count >= 2, routeMeters >= 50 {
            movement = followed
        } else {
            movement = distanceTimeline(
                distanceSamples,
                workoutStart: workoutStart,
                workoutEnd: workoutEnd,
                referenceDistanceMeters: referenceDistanceMeters
            )
        }
        return Track(
            pace: pace(from: movement),
            splits: splits(from: movement, heartRate: heartRate, cadence: cadence),
            elevation: elevation(route, workoutStart: workoutStart, workoutEnd: workoutEnd)
        )
    }

    private struct TimedDistance {
        var second: Double
        var meters: Double
    }

    static func second(_ date: Date, start: Date, end: Date) -> Double {
        let raw = date.timeIntervalSince(start)
        guard raw.isFinite else { return 0 }
        let duration = end.timeIntervalSince(start)
        if duration > 0 {
            return min(max(0, raw), duration)
        }
        return max(0, raw)
    }

    /// Keeps the later sample when two land on the same second, then thins very long traces.
    static func capped(_ points: [SeriesPoint]) -> [SeriesPoint] {
        var unique: [SeriesPoint] = []
        for point in points.sorted(by: { $0.second < $1.second }) {
            guard point.second.isFinite, point.value.isFinite else { continue }
            if let last = unique.last {
                if point.second < last.second { continue }
                if point.second == last.second {
                    unique[unique.count - 1] = point
                    continue
                }
            }
            unique.append(point)
        }
        guard unique.count > maxPoints else { return unique }
        let lastIndex = unique.count - 1
        var kept: [SeriesPoint] = []
        var seen = Set<Int>()
        let step = Double(lastIndex) / Double(maxPoints - 1)
        for slot in 0..<maxPoints {
            let index = min(lastIndex, Int((Double(slot) * step).rounded()))
            if seen.insert(index).inserted {
                kept.append(unique[index])
            }
        }
        return kept
    }

    private static func routeTimeline(
        _ route: [GeoPoint],
        workoutStart: Date,
        workoutEnd: Date
    ) -> [TimedDistance] {
        let stamped = route.compactMap { point -> (second: Double, latitude: Double, longitude: Double)? in
            guard let time = point.timestamp else { return nil }
            guard point.latitude.isFinite, point.longitude.isFinite else { return nil }
            return (
                second(time, start: workoutStart, end: workoutEnd),
                point.latitude,
                point.longitude
            )
        }.sorted { $0.second < $1.second }
        guard let first = stamped.first else { return [] }
        var timeline = [TimedDistance(second: first.second, meters: 0)]
        var traveled = 0.0
        var anchor = first
        for point in stamped.dropFirst() {
            let dt = point.second - anchor.second
            guard dt > 0 else { continue }
            let meters = haversine(anchor.latitude, anchor.longitude, point.latitude, point.longitude)
            let speed = meters / dt
            if speed > 12 || meters > 250 {
                anchor = point
                continue
            }
            guard meters > 0 else {
                anchor = point
                continue
            }
            traveled += meters
            timeline.append(TimedDistance(second: point.second, meters: traveled))
            anchor = point
        }
        return timeline
    }

    private static func distanceTimeline(
        _ samples: [HealthQuantitySample],
        workoutStart: Date,
        workoutEnd: Date,
        referenceDistanceMeters: Double
    ) -> [TimedDistance] {
        let usable = samples
            .filter { $0.value.isFinite && $0.value > 0 && $0.end > $0.start && $0.end >= workoutStart && $0.start <= workoutEnd }
            .sorted { $0.start < $1.start }
        guard let last = usable.last else { return [] }
        let sum = usable.reduce(0) { $0 + $1.value }
        let monotonic = usable.count >= 2 && zip(usable, usable.dropFirst()).allSatisfy { $0.value <= $1.value + 0.5 }
        let matchesWorkout = referenceDistanceMeters > 0
            && abs(last.value - referenceDistanceMeters) / referenceDistanceMeters < 0.35
        let cumulative = monotonic && matchesWorkout && sum > referenceDistanceMeters * 1.3
        var timeline: [TimedDistance] = []
        var traveled = 0.0
        var previous = 0.0
        for sample in usable {
            let delta = cumulative ? max(0, sample.value - previous) : sample.value
            if cumulative { previous = sample.value }
            guard delta > 0 else { continue }
            let startSecond = second(sample.start, start: workoutStart, end: workoutEnd)
            let endSecond = second(sample.end, start: workoutStart, end: workoutEnd)
            if timeline.isEmpty {
                timeline.append(TimedDistance(second: startSecond, meters: 0))
            }
            traveled += delta
            let pointSecond = max(endSecond, timeline[timeline.count - 1].second)
            if pointSecond == timeline[timeline.count - 1].second {
                timeline[timeline.count - 1] = TimedDistance(second: pointSecond, meters: traveled)
            } else {
                timeline.append(TimedDistance(second: pointSecond, meters: traveled))
            }
        }
        return timeline
    }

    private static func pace(from timeline: [TimedDistance]) -> [SeriesPoint] {
        guard timeline.count >= 2 else { return [] }
        var points: [SeriesPoint] = []
        var anchor = timeline[0]
        for (index, sample) in timeline.enumerated() where index > 0 {
            let distance = sample.meters - anchor.meters
            let dt = sample.second - anchor.second
            let isLast = index == timeline.count - 1
            let ready = distance >= 40 || (distance >= 12 && dt >= 10) || (isLast && distance >= 12)
            guard dt > 0, distance > 0, ready else { continue }
            let secondsPerKilometer = dt / (distance / 1000)
            guard secondsPerKilometer.isFinite, secondsPerKilometer > 0, secondsPerKilometer < 3_600 else {
                anchor = sample
                continue
            }
            points.append(SeriesPoint(second: sample.second, value: secondsPerKilometer))
            anchor = sample
        }
        return capped(points)
    }

    private static func splits(
        from timeline: [TimedDistance],
        heartRate: [SeriesPoint],
        cadence: [SeriesPoint]
    ) -> [KilometerSplit] {
        guard let first = timeline.first, let last = timeline.last, last.meters > 30 else { return [] }
        var splits: [KilometerSplit] = []
        var splitStart = first.second
        var nextKilometer = 1
        var cursor = 1
        while cursor < timeline.count, nextKilometer <= 300 {
            let previous = timeline[cursor - 1]
            let current = timeline[cursor]
            let target = Double(nextKilometer) * 1000
            guard current.meters >= target, current.meters > previous.meters else {
                cursor += 1
                continue
            }
            let fraction = (target - previous.meters) / (current.meters - previous.meters)
            let crossed = previous.second + (current.second - previous.second) * fraction
            let dt = crossed - splitStart
            if dt > 0 {
                splits.append(KilometerSplit(
                    index: splits.count + 1,
                    paceSecPerKm: dt,
                    cadence: mean(cadence, from: splitStart, to: crossed, includingEnd: false),
                    heartRate: mean(heartRate, from: splitStart, to: crossed, includingEnd: false),
                    partial: false
                ))
                splitStart = crossed
            }
            nextKilometer += 1
        }
        let leftover = last.meters - Double(nextKilometer - 1) * 1000
        let dt = last.second - splitStart
        if leftover > 30, dt > 0 {
            splits.append(KilometerSplit(
                index: splits.count + 1,
                paceSecPerKm: dt / (leftover / 1000),
                cadence: mean(cadence, from: splitStart, to: last.second, includingEnd: true),
                heartRate: mean(heartRate, from: splitStart, to: last.second, includingEnd: true),
                partial: true
            ))
        }
        return splits
    }

    private static func mean(
        _ points: [SeriesPoint],
        from start: Double,
        to end: Double,
        includingEnd: Bool
    ) -> Double {
        let values = points.compactMap { point -> Double? in
            guard point.value.isFinite, point.value > 0, point.second >= start else { return nil }
            if includingEnd {
                guard point.second <= end else { return nil }
            } else if point.second >= end {
                return nil
            }
            return point.value
        }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func elevation(
        _ route: [GeoPoint],
        workoutStart: Date,
        workoutEnd: Date
    ) -> [SeriesPoint] {
        let stamped = route.compactMap { point -> SeriesPoint? in
            guard let time = point.timestamp, point.altitude.isFinite else { return nil }
            return SeriesPoint(second: second(time, start: workoutStart, end: workoutEnd), value: point.altitude)
        }
        if stamped.count >= 2 {
            return capped(stamped)
        }
        let span = max(workoutEnd.timeIntervalSince(workoutStart), 0)
        let lastIndex = Double(route.count - 1)
        let spread = route.enumerated().compactMap { index, point -> SeriesPoint? in
            guard point.altitude.isFinite else { return nil }
            let elapsed = lastIndex > 0 ? span * Double(index) / lastIndex : 0
            return SeriesPoint(second: elapsed, value: point.altitude)
        }
        return capped(spread)
    }

    private static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6_371_000.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(max(0, a))))
    }
}
