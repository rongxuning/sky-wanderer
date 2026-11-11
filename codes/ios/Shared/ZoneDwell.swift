import Foundation

struct ZoneBand {
    var name: String
    var range: String
    var lower: Double
    var upper: Double

    func contains(_ value: Double) -> Bool {
        value >= lower && value < upper
    }
}

struct ZoneShare: Identifiable {
    var name: String
    var range: String
    var seconds: Double
    var fraction: Double

    var id: String { name }
}

/// Time in the detail-page chart bands.
///
/// `WorkoutDetailMath.shares` and Edwards session load both call `shares`, so the
/// heart-rate zone card and the list-card load count the same seconds.
enum ZoneDwell {
    /// Same draft cutoffs as `ZoneScale.heart` (190 bpm reference, not a lab test).
    /// Order is Z1…Z5. Edwards weights are that order: 1, 2, 3, 4, 5.
    static let heartBands: [ZoneBand] = [
        ZoneBand(name: "有氧基础", range: "<114", lower: 0.001, upper: 114),
        ZoneBand(name: "有氧耐力", range: "114–132", lower: 114, upper: 133),
        ZoneBand(name: "乳酸阈值", range: "133–151", lower: 133, upper: 152),
        ZoneBand(name: "速度耐力", range: "152–170", lower: 152, upper: 171),
        ZoneBand(name: "冲刺能力", range: "≥171", lower: 171, upper: .infinity)
    ]

    /// Zone number 1…5 for one heart rate. Matches `ZoneScale.heart`.
    /// A reading below the chart band's 0.001 bpm floor is still zone 1.
    static func heartZone(_ bpm: Double) -> Int {
        if let index = heartBands.firstIndex(where: { $0.contains(bpm) }) {
            return index + 1
        }
        if bpm < heartBands[0].upper { return 1 }
        return heartBands.count
    }

    /// Finite samples above zero. The heart-rate zone card drops the rest before `shares`.
    static func positiveSamples(_ points: [SeriesPoint]) -> [SeriesPoint] {
        points.filter { $0.value.isFinite && $0.value > 0 }
    }

    /// Time in each band.
    ///
    /// A gap longer than `TrainingSeriesMath.pauseGapSeconds` is a pause and is
    /// left out, matching the training average. That rule is right for pace,
    /// which is sampled about every 10–20 seconds of movement.
    ///
    /// Heart rate is not. HealthKit samples are thinned to `HealthSeries.maxPoints`
    /// (720). On a long workout the stored points sit more than 30 seconds apart,
    /// so every interval was classified as a pause and every zone reported 0%
    /// while the chart still drew the series. When the pause rule counts nothing,
    /// treat the series' own spacing as the sample interval: keep gaps up to
    /// 1.5× the median, drop a hole that is much longer, and split each kept
    /// interval across the bands the value crosses.
    static func shares(points: [SeriesPoint], bands: [ZoneBand]) -> [ZoneShare] {
        let ordered = uniqued(points)
        let held = dwell(ordered, bands: bands, limit: TrainingSeriesMath.pauseGapSeconds, interpolate: false)
        if held.reduce(0, +) > 0 || ordered.count < 2 {
            return packaged(bands, held)
        }
        let gaps = (1..<ordered.count).map { ordered[$0].second - ordered[$0 - 1].second }.filter { $0 > 0 }
        guard let typical = median(gaps) else { return packaged(bands, held) }
        let limit = max(TrainingSeriesMath.pauseGapSeconds, typical * 1.5)
        let crossed = dwell(ordered, bands: bands, limit: limit, interpolate: true)
        return packaged(bands, crossed)
    }

    /// Band edges strictly between two readings, in the direction of travel.
    /// The heart-rate and pace strokes split on these same edges.
    static func edges(between start: Double, and end: Double, bands: [ZoneBand]) -> [Double] {
        guard start.isFinite, end.isFinite, start != end else { return [] }
        let low = min(start, end)
        let high = max(start, end)
        var found: [Double] = []
        for band in bands {
            for edge in [band.lower, band.upper] where edge.isFinite && edge > low && edge < high {
                if found.allSatisfy({ abs($0 - edge) > 0.000_001 }) {
                    found.append(edge)
                }
            }
        }
        found.sort()
        if start > end { found.reverse() }
        return found
    }

    private static func dwell(
        _ ordered: [SeriesPoint],
        bands: [ZoneBand],
        limit: Double,
        interpolate: Bool
    ) -> [Double] {
        var seconds = Array(repeating: 0.0, count: bands.count)
        guard ordered.count >= 2 else { return seconds }
        for index in 1..<ordered.count {
            let dt = ordered[index].second - ordered[index - 1].second
            guard dt > 0, dt <= limit else { continue }
            let start = ordered[index - 1].value
            let end = ordered[index].value
            if interpolate && start != end {
                addCrossed(&seconds, from: start, to: end, dt: dt, bands: bands)
            } else if let band = bands.firstIndex(where: { $0.contains(start) }) {
                seconds[band] += dt
            }
        }
        return seconds
    }

    /// Linear in time. The fraction of the interval between two values is the
    /// fraction of `dt`, which is the same split the heart-rate stroke uses.
    private static func addCrossed(
        _ seconds: inout [Double],
        from start: Double,
        to end: Double,
        dt: Double,
        bands: [ZoneBand]
    ) {
        let span = end - start
        guard span != 0 else { return }
        var knots = [start]
        knots.append(contentsOf: edges(between: start, and: end, bands: bands))
        knots.append(end)
        for index in 1..<knots.count {
            let share = abs(knots[index] - knots[index - 1]) / abs(span) * dt
            let probe = knots[index - 1] + (knots[index] - knots[index - 1]) * 0.5
            guard let band = bands.firstIndex(where: { $0.contains(probe) }) else { continue }
            seconds[band] += share
        }
    }

    private static func packaged(_ bands: [ZoneBand], _ seconds: [Double]) -> [ZoneShare] {
        let total = seconds.reduce(0, +)
        return zip(bands, seconds).map { band, time in
            ZoneShare(
                name: band.name,
                range: band.range,
                seconds: time,
                fraction: total > 0 ? time / total : 0
            )
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func uniqued(_ points: [SeriesPoint]) -> [SeriesPoint] {
        var result: [SeriesPoint] = []
        var last = -Double.greatestFiniteMagnitude
        for point in points.sorted(by: { $0.second < $1.second }) {
            guard point.second.isFinite, point.value.isFinite, point.second > last else { continue }
            result.append(point)
            last = point.second
        }
        return result
    }
}
