import Foundation

/// Sampling and pace-axis math for the workout detail charts.
///
/// Stored series are already limited to `HealthSeries.maxPoints` (720) at ingest.
/// Plotting does not thin them again. The pace axis stays inverted: a smaller
/// seconds-per-kilometer value is faster and sits at the top.
enum WorkoutChartMath {
    /// No plot-time cap. Pass a smaller `limit` only when a caller still wants to thin a series.
    static let plotLimit = Int.max

    /// Evenly samples the series and always keeps the minimum and maximum.
    /// Times stay strictly increasing. The point cap is honored unless the only
    /// remaining points are those extrema.
    static func plotSamples(_ points: [SeriesPoint], limit: Int = plotLimit) -> [SeriesPoint] {
        let unique = uniqued(points)
        guard unique.count >= 2 else { return [] }
        let cap = max(2, limit)
        let finite = points.filter { $0.second.isFinite && $0.value.isFinite }
        let low = finite.min { $0.value < $1.value }
        let high = finite.max { $0.value < $1.value }

        var chosen: [SeriesPoint]
        if unique.count <= cap {
            chosen = unique
        } else {
            let step = max(1, unique.count / cap)
            chosen = []
            chosen.reserveCapacity(cap)
            for index in stride(from: 0, to: unique.count, by: step) {
                chosen.append(unique[index])
            }
            if let last = unique.last, chosen.last?.second != last.second {
                chosen.append(last)
            }
        }
        return includingExtrema(chosen, low: low, high: high, cap: cap)
    }

    struct PaceScale: Equatable {
        /// Fastest pace in the filtered series, in seconds per kilometer.
        var fastest: Double
        /// Slowest pace still on the scale. Slower samples stay in the series and clip.
        var slowCap: Double
        /// Inverted chart domain. The upper bound is the fast end.
        var domain: ClosedRange<Double>
    }

    /// Pace axis for every finite sample in `0 < pace < 3600`.
    ///
    /// The fast end is the true minimum, not a downsampled subset. The slow end
    /// is a robust cap: at least the 95th percentile, and not tighter than
    /// 1.75× the median, but never past the slowest valid sample. A ~50'/km
    /// outlier therefore stays on the series and falls below the chart.
    static func paceScale(_ points: [SeriesPoint]) -> PaceScale {
        let values = points.map(\.value).filter { $0.isFinite && $0 > 0 && $0 < 3_600 }
        guard let fastest = values.min(), let slowest = values.max() else {
            return padded(fastest: 300, slowCap: 600, clips: false)
        }
        let sorted = values.sorted()
        let typical = median(sorted)
        let rank = percentile95(sorted)
        let slowCap = min(slowest, max(rank, typical * 1.75))
        return padded(fastest: fastest, slowCap: slowCap, clips: slowCap < slowest)
    }

    /// Nearest rank that covers at least 95% of the sorted samples.
    private static func percentile95(_ sorted: [Double]) -> Double {
        let count = sorted.count
        var rank = 1
        while Double(rank) / Double(count) < 0.95 - 1e-12 {
            rank += 1
        }
        return sorted[min(count - 1, rank - 1)]
    }

    private static func median(_ sorted: [Double]) -> Double {
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func padded(fastest: Double, slowCap: Double, clips: Bool) -> PaceScale {
        let pad = max((slowCap - fastest) * 0.18, 15)
        let slowEdge = clips ? slowCap : slowCap + pad
        let fastEdge = fastest - pad
        let lower = -slowEdge
        let upper = -fastEdge
        let domain = upper > lower ? lower...upper : (lower - 1)...(lower + 1)
        return PaceScale(fastest: fastest, slowCap: slowCap, domain: domain)
    }

    /// Inserts the true min and max. A sample already at that time keeps the more extreme value
    /// so the chart does not plot two points on one second. When the minimum and maximum share
    /// a second, the maximum wins: one timestamp can only draw one value.
    private static func includingExtrema(
        _ samples: [SeriesPoint],
        low: SeriesPoint?,
        high: SeriesPoint?,
        cap: Int
    ) -> [SeriesPoint] {
        var rows = samples
        if let high {
            rows = merging(rows, extreme: high, replaces: { $0 > $1 })
        }
        if let low, low.second != high?.second {
            rows = merging(rows, extreme: low, replaces: { $0 < $1 })
        }
        rows.sort { $0.second < $1.second }
        var collapsed: [SeriesPoint] = []
        collapsed.reserveCapacity(rows.count)
        for row in rows {
            if let last = collapsed.last, last.second == row.second {
                if row.value == high?.value || (row.value == low?.value && last.value != high?.value) {
                    collapsed[collapsed.count - 1] = SeriesPoint(second: row.second, value: row.value)
                }
            } else {
                collapsed.append(row)
            }
        }
        guard collapsed.count > cap else { return collapsed }
        let protected = Set([low?.second, high?.second].compactMap { $0 })
        var trimmed = collapsed
        while trimmed.count > cap {
            let middle = trimmed.indices.filter { index in
                let second = trimmed[index].second
                if protected.contains(second) { return false }
                return index != 0 && index != trimmed.count - 1
            }
            let pool = middle.isEmpty
                ? trimmed.indices.filter { !protected.contains(trimmed[$0].second) }
                : middle
            guard !pool.isEmpty else { break }
            trimmed.remove(at: pool[pool.count / 2])
        }
        return trimmed
    }

    private static func merging(
        _ rows: [SeriesPoint],
        extreme: SeriesPoint,
        replaces: (Double, Double) -> Bool
    ) -> [SeriesPoint] {
        if let index = rows.firstIndex(where: { $0.second == extreme.second }) {
            guard replaces(extreme.value, rows[index].value) else { return rows }
            var copy = rows
            copy[index] = SeriesPoint(second: extreme.second, value: extreme.value)
            return copy
        }
        return rows + [SeriesPoint(second: extreme.second, value: extreme.value)]
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
