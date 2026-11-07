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
    ///
    /// Kilometer cuts use `referenceDistanceMeters` when that official distance is
    /// trustworthy: the route (or the distance samples) only decides when each meter
    /// happened, then the timeline is scaled so the last point matches the official
    /// total. Split durations use moving time. A gap longer than
    /// `TrainingSeriesMath.pauseGapSeconds` whose speed is under 0.5 m/s is a pause
    /// or a GPS hole and adds no time. When `trainingDuration` is the workout's
    /// moving time, split durations are scaled so they sum to it.
    static func track(
        route: [GeoPoint],
        distanceSamples: [HealthQuantitySample],
        workoutStart: Date,
        workoutEnd: Date,
        referenceDistanceMeters: Double,
        heartRate: [SeriesPoint],
        cadence: [SeriesPoint],
        trainingDuration: TimeInterval = 0
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
        let aligned = alignedToOfficialDistance(movement, officialMeters: referenceDistanceMeters)
        return Track(
            pace: pace(from: movement),
            splits: splits(
                from: aligned,
                heartRate: heartRate,
                cadence: cadence,
                trainingDuration: trainingDuration
            ),
            elevation: elevation(route, workoutStart: workoutStart, workoutEnd: workoutEnd)
        )
    }

    private struct TimedDistance {
        /// Seconds after the workout start, on the wall clock. Heart rate and cadence
        /// samples use this axis.
        var second: Double
        /// Moving seconds, with pauses and long GPS holes removed.
        var movingSecond: Double
        var meters: Double
    }

    /// Official workout distance is trustworthy when both totals are real and within
    /// a factor of two. A mountain GPS trace often lands a little short of HealthKit;
    /// a trace that is half or twice the official distance is left alone.
    private static func alignedToOfficialDistance(
        _ timeline: [TimedDistance],
        officialMeters: Double
    ) -> [TimedDistance] {
        guard let last = timeline.last, last.meters >= 50,
              officialMeters.isFinite, officialMeters >= 50 else { return timeline }
        let ratio = officialMeters / last.meters
        guard ratio >= 0.5, ratio <= 2 else { return timeline }
        guard abs(last.meters - officialMeters) > 0.5 else { return timeline }
        return timeline.map {
            TimedDistance(second: $0.second, movingSecond: $0.movingSecond, meters: $0.meters * ratio)
        }
    }

    /// Time credited to one movement segment. Long, near-stopped gaps are pauses.
    private static func movingCredit(dt: Double, meters: Double) -> Double {
        guard dt.isFinite, dt > 0, meters.isFinite, meters > 0 else { return 0 }
        if dt > TrainingSeriesMath.pauseGapSeconds, meters / dt < 0.5 {
            return 0
        }
        return dt
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
        var timeline = [TimedDistance(second: first.second, movingSecond: 0, meters: 0)]
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
            let moving = timeline[timeline.count - 1].movingSecond + movingCredit(dt: dt, meters: meters)
            timeline.append(TimedDistance(second: point.second, movingSecond: moving, meters: traveled))
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
                timeline.append(TimedDistance(second: startSecond, movingSecond: 0, meters: 0))
            }
            traveled += delta
            let previous = timeline[timeline.count - 1]
            let pointSecond = max(endSecond, previous.second)
            let sampleDt = max(0, endSecond - startSecond)
            let moving = previous.movingSecond + movingCredit(dt: sampleDt, meters: delta)
            if pointSecond == previous.second {
                timeline[timeline.count - 1] = TimedDistance(second: pointSecond, movingSecond: moving, meters: traveled)
            } else {
                timeline.append(TimedDistance(second: pointSecond, movingSecond: moving, meters: traveled))
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
        cadence: [SeriesPoint],
        trainingDuration: TimeInterval
    ) -> [KilometerSplit] {
        guard let first = timeline.first, let last = timeline.last, last.meters > 30 else { return [] }
        var splits: [KilometerSplit] = []
        var splitStartWall = first.second
        var splitStartMoving = first.movingSecond
        var nextKilometer = 1
        var cursor = 1
        while cursor < timeline.count, nextKilometer <= 500 {
            let previous = timeline[cursor - 1]
            let current = timeline[cursor]
            let target = Double(nextKilometer) * 1000
            guard current.meters >= target, current.meters > previous.meters else {
                cursor += 1
                continue
            }
            let fraction = (target - previous.meters) / (current.meters - previous.meters)
            let crossedWall = previous.second + (current.second - previous.second) * fraction
            let crossedMoving = previous.movingSecond + (current.movingSecond - previous.movingSecond) * fraction
            let dt = max(0, crossedMoving - splitStartMoving)
            splits.append(KilometerSplit(
                index: splits.count + 1,
                paceSecPerKm: dt,
                cadence: mean(cadence, from: splitStartWall, to: crossedWall, includingEnd: false),
                heartRate: mean(heartRate, from: splitStartWall, to: crossedWall, includingEnd: false),
                partial: false,
                energyKilocalories: 0,
                distanceMeters: 1000,
                durationSeconds: dt
            ))
            splitStartWall = crossedWall
            splitStartMoving = crossedMoving
            nextKilometer += 1
        }
        let leftover = last.meters - Double(nextKilometer - 1) * 1000
        let dt = max(0, last.movingSecond - splitStartMoving)
        if leftover > 30, dt > 0 {
            splits.append(KilometerSplit(
                index: splits.count + 1,
                paceSecPerKm: dt / (leftover / 1000),
                cadence: mean(cadence, from: splitStartWall, to: last.second, includingEnd: true),
                heartRate: mean(heartRate, from: splitStartWall, to: last.second, includingEnd: true),
                partial: true,
                energyKilocalories: 0,
                distanceMeters: leftover,
                durationSeconds: dt
            ))
        }
        return fitted(splits, to: trainingDuration)
    }

    /// Scales split durations so they add up to the workout's training time.
    private static func fitted(_ splits: [KilometerSplit], to trainingDuration: TimeInterval) -> [KilometerSplit] {
        guard trainingDuration.isFinite, trainingDuration > 0 else { return splits }
        let sum = splits.reduce(0.0) { $0 + max(0, $1.durationSeconds) }
        guard sum > 0 else { return splits }
        let factor = trainingDuration / sum
        guard abs(factor - 1) > 0.0001 else { return splits }
        return splits.map { split in
            var copy = split
            copy.durationSeconds = split.durationSeconds * factor
            let kilometers = split.distanceMeters / 1000
            if kilometers > 0 {
                copy.paceSecPerKm = copy.durationSeconds / kilometers
            }
            return copy
        }
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

extension WorkoutRecord {
    /// Kilometer rows for the detail table and the share image.
    /// Stored splits from an older import were cut on the raw GPS length and have no
    /// leftover distance, so they are rebuilt from the saved route, official distance,
    /// and training time. A record that already matches that distance keeps its splits.
    var resolvedSplits: [KilometerSplit] {
        guard distanceMeters > 30 else { return splits }
        if splitsMatchOfficialDistance() { return splits }
        let rebuilt = HealthSeries.track(
            route: route,
            distanceSamples: [],
            workoutStart: start,
            workoutEnd: end,
            referenceDistanceMeters: distanceMeters,
            heartRate: heartRate,
            cadence: cadenceSeries,
            trainingDuration: storedTrainingDuration
        ).splits
        return rebuilt.isEmpty ? splits : rebuilt
    }

    /// Moving time actually stored on the record. `0` when the file only has elapsed time.
    private var storedTrainingDuration: TimeInterval {
        guard trainingDurationSeconds.isFinite,
              trainingDurationSeconds > 0,
              elapsedDuration.isFinite,
              trainingDurationSeconds <= elapsedDuration else { return 0 }
        return trainingDurationSeconds
    }

    /// True when the saved rows already use the official distance, including a measured leftover.
    private func splitsMatchOfficialDistance() -> Bool {
        guard distanceMeters >= 50, !splits.isEmpty else { return false }
        guard splits.allSatisfy({ $0.durationSeconds > 0 }) else { return false }
        let full = Int(distanceMeters / 1000)
        let remainder = distanceMeters - Double(full) * 1000
        let completed = splits.filter { !$0.partial }
        guard completed.count == full else { return false }
        guard completed.allSatisfy({ abs($0.distanceMeters - 1000) < 5 }) else { return false }
        if remainder > 30 {
            guard let last = splits.last, last.partial, last.distanceMeters > 0 else { return false }
            guard abs(last.distanceMeters - remainder) < 15 else { return false }
        } else if splits.contains(where: \.partial) {
            return false
        }
        if storedTrainingDuration > 0 {
            let sum = splits.reduce(0.0) { $0 + max(0, $1.durationSeconds) }
            guard sum > 0, abs(sum - storedTrainingDuration) / storedTrainingDuration <= 0.03 else { return false }
        }
        return true
    }
}
