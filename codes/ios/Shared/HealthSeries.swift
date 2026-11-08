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
        /// Official cumulative meters, kept only when the distance samples match the workout total.
        var distanceProgress: [SeriesPoint]
        var pauseIntervals: [WorkoutPause]
    }

    /// Pace prefers a timestamped route. Elevation always comes from route altitudes.
    ///
    /// Kilometer cuts prefer HealthKit distance samples when their total is within
    /// 15% of `referenceDistanceMeters`. Each kilometer ends where that cumulative
    /// distance crossed the mark. A GPS trace is only the fallback: scaling it so
    /// the last point matches the official total still leaves local trail error in
    /// every cut. Recorded pauses are removed from split duration. With no pause
    /// events, a GPS gap longer than `TrainingSeriesMath.pauseGapSeconds` whose
    /// speed is under 0.5 m/s still adds no time. When `trainingDuration` is the
    /// workout's moving time, split durations are scaled so they sum to it.
    static func track(
        route: [GeoPoint],
        distanceSamples: [HealthQuantitySample],
        workoutStart: Date,
        workoutEnd: Date,
        referenceDistanceMeters: Double,
        heartRate: [SeriesPoint],
        cadence: [SeriesPoint],
        trainingDuration: TimeInterval = 0,
        pauses: [WorkoutPause] = []
    ) -> Track {
        let pauseList = WorkoutPause.merged(pauses)
        let followed = routeTimeline(route, workoutStart: workoutStart, workoutEnd: workoutEnd)
        let sampled = distanceTimeline(
            distanceSamples,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            referenceDistanceMeters: referenceDistanceMeters
        )
        let progress = progressSeries(sampled)
        let routeUsable = followed.count >= 2 && (followed.last?.meters ?? 0) >= 50
        let official = trustedOfficialDistance(progress, officialMeters: referenceDistanceMeters)
        let paceTimeline: [TimedDistance]
        if routeUsable {
            paceTimeline = followed
        } else {
            paceTimeline = progress.map { TimedDistance(second: $0.second, movingSecond: 0, meters: $0.value) }
        }
        let splitTimeline: [TimedDistance]
        if official {
            splitTimeline = timed(progress, pauses: pauseList, inferSlowGaps: false)
        } else if routeUsable {
            splitTimeline = applyingPauses(followed, pauseList)
        } else {
            splitTimeline = timed(progress, pauses: pauseList, inferSlowGaps: true)
        }
        let aligned = alignedToOfficialDistance(splitTimeline, officialMeters: referenceDistanceMeters)
        return Track(
            pace: pace(from: paceTimeline),
            splits: splits(
                from: aligned,
                heartRate: heartRate,
                cadence: cadence,
                trainingDuration: trainingDuration,
                pauses: pauseList
            ),
            elevation: elevation(route, workoutStart: workoutStart, workoutEnd: workoutEnd),
            distanceProgress: official ? progress : [],
            pauseIntervals: pauseList
        )
    }

    /// Kilometer rows from a stored official distance curve.
    /// Returns nothing when the curve is missing or its total is not the workout distance,
    /// so the caller can keep GPS fallback.
    static func splits(
        distanceProgress: [SeriesPoint],
        pauses: [WorkoutPause],
        heartRate: [SeriesPoint],
        cadence: [SeriesPoint],
        trainingDuration: TimeInterval,
        referenceDistanceMeters: Double
    ) -> [KilometerSplit] {
        guard trustedOfficialDistance(distanceProgress, officialMeters: referenceDistanceMeters) else { return [] }
        let pauseList = WorkoutPause.merged(pauses)
        let timeline = timed(distanceProgress, pauses: pauseList, inferSlowGaps: false)
        let aligned = alignedToOfficialDistance(timeline, officialMeters: referenceDistanceMeters)
        return splits(
            from: aligned,
            heartRate: heartRate,
            cadence: cadence,
            trainingDuration: trainingDuration,
            pauses: pauseList
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

    /// Cumulative meters at wall-clock seconds. A gap between samples keeps the
    /// distance flat so that gap is not later counted as moving time.
    /// A monotonic series whose last value matches the workout, and whose sum is
    /// much larger than that workout, is a running total and is differenced.
    private static func distanceTimeline(
        _ samples: [HealthQuantitySample],
        workoutStart: Date,
        workoutEnd: Date,
        referenceDistanceMeters: Double
    ) -> [SeriesPoint] {
        let usable = samples
            .filter { $0.value.isFinite && $0.value > 0 && $0.end > $0.start && $0.end >= workoutStart && $0.start <= workoutEnd }
            .sorted { $0.start < $1.start }
        guard let last = usable.last else { return [] }
        let sum = usable.reduce(0) { $0 + $1.value }
        let monotonic = usable.count >= 2 && zip(usable, usable.dropFirst()).allSatisfy { $0.value <= $1.value + 0.5 }
        let matchesWorkout = referenceDistanceMeters > 0
            && abs(last.value - referenceDistanceMeters) / referenceDistanceMeters < 0.35
        let cumulative = monotonic && matchesWorkout && sum > referenceDistanceMeters * 1.3
        var points: [SeriesPoint] = []
        var traveled = 0.0
        var previousValue = 0.0
        func add(second: Double, meters: Double) {
            if let last = points.last {
                if second < last.second { return }
                if second == last.second {
                    if meters > last.value {
                        points[points.count - 1] = SeriesPoint(second: second, value: meters)
                    }
                    return
                }
            }
            points.append(SeriesPoint(second: second, value: meters))
        }
        for sample in usable {
            let delta = cumulative ? max(0, sample.value - previousValue) : sample.value
            if cumulative { previousValue = sample.value }
            guard delta > 0 else { continue }
            let startSecond = second(sample.start, start: workoutStart, end: workoutEnd)
            let endSecond = second(sample.end, start: workoutStart, end: workoutEnd)
            if points.isEmpty {
                add(second: startSecond, meters: 0)
            } else if startSecond > points[points.count - 1].second {
                add(second: startSecond, meters: traveled)
            }
            traveled += delta
            let pointSecond = max(endSecond, points.last?.second ?? endSecond)
            add(second: pointSecond, meters: traveled)
        }
        return points
    }

    /// Distance samples are the official curve when they land within 15% of the workout total.
    private static func trustedOfficialDistance(_ progress: [SeriesPoint], officialMeters: Double) -> Bool {
        guard let last = progress.last, last.value >= 50,
              officialMeters.isFinite, officialMeters >= 50 else { return false }
        let ratio = officialMeters / last.value
        return ratio >= 0.85 && ratio <= 1.15
    }

    private static let splitProgressMaxPoints = 4096

    /// Keeps gap markers (flat distance) and thins the rest. The last sample stays,
    /// so the official total used for the trust check does not change.
    private static func progressSeries(_ points: [SeriesPoint]) -> [SeriesPoint] {
        guard points.count > splitProgressMaxPoints else { return points }
        var keep = Set<Int>([0, points.count - 1])
        for index in 1..<points.count where abs(points[index].value - points[index - 1].value) <= 0.5 {
            keep.insert(index - 1)
            keep.insert(index)
        }
        let extras = splitProgressMaxPoints - keep.count
        if extras > 0 {
            let optional = points.indices.filter { !keep.contains($0) }
            if !optional.isEmpty {
                let step = Double(optional.count) / Double(extras)
                for slot in 0..<extras {
                    let pick = min(optional.count - 1, Int((Double(slot) * step).rounded(.down)))
                    keep.insert(optional[pick])
                }
            }
        } else if keep.count > splitProgressMaxPoints {
            let required = keep.sorted()
            let lastIndex = required.count - 1
            var slim: [Int] = []
            var seen = Set<Int>()
            let step = Double(lastIndex) / Double(splitProgressMaxPoints - 1)
            for slot in 0..<splitProgressMaxPoints {
                let index = required[min(lastIndex, Int((Double(slot) * step).rounded()))]
                if seen.insert(index).inserted {
                    slim.append(index)
                }
            }
            if slim.last != required[lastIndex] {
                slim.append(required[lastIndex])
            }
            return slim.map { points[$0] }
        }
        return keep.sorted().map { points[$0] }
    }

    private struct Span {
        var start: Double
        var end: Double
    }

    /// Wall-clock pieces of `[start, end)` that are not inside a pause.
    private static func activePieces(from start: Double, to end: Double, pauses: [WorkoutPause]) -> [Span] {
        guard end > start else { return [] }
        var pieces: [Span] = []
        var cursor = start
        let cuts = pauses
            .filter { $0.endSecond > start && $0.startSecond < end }
            .sorted { $0.startSecond < $1.startSecond }
        for pause in cuts {
            let pauseStart = max(start, pause.startSecond)
            let pauseEnd = min(end, pause.endSecond)
            if pauseStart > cursor {
                pieces.append(Span(start: cursor, end: pauseStart))
            }
            cursor = max(cursor, pauseEnd)
        }
        if cursor < end {
            pieces.append(Span(start: cursor, end: end))
        }
        return pieces
    }

    /// Moving time along a cumulative distance curve.
    /// Flat gaps add no time. Distance that spans a pause is spread across the
    /// active pieces only, so a kilometer boundary cannot land inside the pause.
    /// `inferSlowGaps` drops a long, near-stopped GPS-style segment when no pause
    /// events were recorded. Official distance samples do not use it: a slow trail
    /// kilometer is still moving time.
    private static func timed(
        _ progress: [SeriesPoint],
        pauses: [WorkoutPause],
        inferSlowGaps: Bool
    ) -> [TimedDistance] {
        let points = progress
            .filter { $0.second.isFinite && $0.value.isFinite && $0.value >= 0 }
            .sorted { $0.second < $1.second }
        guard let first = points.first else { return [] }
        var timeline = [TimedDistance(second: first.second, movingSecond: 0, meters: first.value)]
        for point in points.dropFirst() {
            let previous = timeline[timeline.count - 1]
            let span = point.second - previous.second
            guard span > 0 else { continue }
            let delta = point.value - previous.meters
            if delta <= 0.5 {
                timeline.append(TimedDistance(second: point.second, movingSecond: previous.movingSecond, meters: previous.meters))
                continue
            }
            let pieces = activePieces(from: previous.second, to: point.second, pauses: pauses)
            if pieces.isEmpty {
                timeline.append(TimedDistance(
                    second: point.second,
                    movingSecond: previous.movingSecond,
                    meters: max(previous.meters, point.value)
                ))
                continue
            }
            let active = pieces.reduce(0) { $0 + ($1.end - $1.start) }
            if inferSlowGaps, pauses.isEmpty, span > TrainingSeriesMath.pauseGapSeconds, delta / span < 0.5 {
                timeline.append(TimedDistance(second: point.second, movingSecond: previous.movingSecond, meters: previous.meters + delta))
                continue
            }
            var carried = previous.meters
            var moving = previous.movingSecond
            for piece in pieces {
                let dt = piece.end - piece.start
                let share = active > 0 ? delta * (dt / active) : 0
                carried += share
                moving += dt
                timeline.append(TimedDistance(second: piece.end, movingSecond: moving, meters: carried))
            }
        }
        return timeline
    }

    /// Subtracts recorded pauses from a GPS timeline without removing a gap the
    /// speed heuristic already dropped.
    private static func applyingPauses(_ timeline: [TimedDistance], _ pauses: [WorkoutPause]) -> [TimedDistance] {
        guard !pauses.isEmpty, timeline.count >= 2 else { return timeline }
        var result = [timeline[0]]
        for index in 1..<timeline.count {
            let previous = timeline[index - 1]
            let current = timeline[index]
            let movingDelta = max(0, current.movingSecond - previous.movingSecond)
            let paused = WorkoutPause.overlap(pauses, from: previous.second, to: current.second)
            let credit = movingDelta <= 0.5 ? 0 : max(0, movingDelta - paused)
            let last = result[result.count - 1]
            result.append(TimedDistance(
                second: current.second,
                movingSecond: last.movingSecond + credit,
                meters: current.meters
            ))
        }
        return result
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
        trainingDuration: TimeInterval,
        pauses: [WorkoutPause]
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
                cadence: mean(cadence, from: splitStartWall, to: crossedWall, includingEnd: false, pauses: pauses),
                heartRate: mean(heartRate, from: splitStartWall, to: crossedWall, includingEnd: false, pauses: pauses),
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
                cadence: mean(cadence, from: splitStartWall, to: last.second, includingEnd: true, pauses: pauses),
                heartRate: mean(heartRate, from: splitStartWall, to: last.second, includingEnd: true, pauses: pauses),
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
        includingEnd: Bool,
        pauses: [WorkoutPause]
    ) -> Double {
        let values = points.compactMap { point -> Double? in
            guard point.value.isFinite, point.value > 0, point.second >= start else { return nil }
            if includingEnd {
                guard point.second <= end else { return nil }
            } else if point.second >= end {
                return nil
            }
            if pauses.contains(where: { point.second >= $0.startSecond && point.second < $0.endSecond }) {
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
    /// An official distance curve cuts each kilometer where HealthKit distance crossed
    /// that mark and leaves recorded pauses out of the row. Older imports have no curve;
    /// the next Health merge stores one, and this rebuilds the rows without rewriting
    /// the saved array. Until that curve exists, stored rows that already use the
    /// official distance are kept, and anything else is rebuilt from the route.
    var resolvedSplits: [KilometerSplit] {
        guard distanceMeters > 30 else { return splits }
        let official = HealthSeries.splits(
            distanceProgress: distanceProgress,
            pauses: pauseIntervals,
            heartRate: heartRate,
            cadence: cadenceSeries,
            trainingDuration: storedTrainingDuration,
            referenceDistanceMeters: distanceMeters
        )
        if !official.isEmpty { return official }
        if splitsMatchOfficialDistance() { return splits }
        let rebuilt = HealthSeries.track(
            route: route,
            distanceSamples: [],
            workoutStart: start,
            workoutEnd: end,
            referenceDistanceMeters: distanceMeters,
            heartRate: heartRate,
            cadence: cadenceSeries,
            trainingDuration: storedTrainingDuration,
            pauses: pauseIntervals
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
