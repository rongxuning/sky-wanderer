import Foundation

/// Framework placeholder for the analysis score card.
///
/// `compositeScore`, `series`, and the dates on `AnalysisScoreCardModel` are a fixed
/// sample so the radar and the sparklines have a shape. They are not computed from
/// `WorkoutRecord`, HealthKit, or `TrainingStats`. Replace this file when the
/// scoring algorithm is implemented. `isFrameworkPlaceholder` stays true until then.
enum AnalysisScoreDimension: String, CaseIterable, Identifiable, Equatable {
    /// Clockwise from the top of the radar.
    case stamina = "体力"
    case strength = "力量"
    case power = "爆发"
    case variety = "多样"
    case technique = "技术"
    case experience = "经验"
    case will = "意志"
    case recovery = "恢复"

    var id: String { rawValue }
    var title: String { rawValue }
}

/// One sample on a dimension's three-month line. The score is a placeholder, not a formula.
struct AnalysisScoreSample: Equatable {
    var date: Date
    /// 0...100 on the sparkline axis.
    var score: Int
}

struct AnalysisScoreTrend: Equatable {
    var dimension: AnalysisScoreDimension
    var samples: [AnalysisScoreSample]
}

/// Inclusive range drawn under 「近三个月」. Always three calendar months, ending at `end`.
struct AnalysisScoreWindow: Equatable {
    var start: Date
    var end: Date

    /// `end` minus three calendar months, in `calendar`. A short destination month clamps
    /// to its last day (May 31 minus three months is February 28 or 29). This is not 90 days.
    static func lastThreeMonths(ending now: Date, calendar: Calendar = AnalysisScoreCalendar.shanghai) -> AnalysisScoreWindow {
        let start = calendar.date(byAdding: .month, value: -3, to: now) ?? now
        return AnalysisScoreWindow(start: start, end: now)
    }
}

enum AnalysisScoreCalendar {
    static var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }
}

/// What the score card draws. Independent of `StatsWindow` and of the workout list.
struct AnalysisScoreCardModel: Equatable {
    /// True while these numbers come from `AnalysisScorePlaceholder` rather than a score algorithm.
    var isFrameworkPlaceholder: Bool
    /// Placeholder composite, shown in primary next to 「综合评分」.
    var composite: Int
    /// Placeholder current score for each axis. Not a training-record aggregate.
    var current: [AnalysisScoreDimension: Int]
    var trends: [AnalysisScoreTrend]
    var window: AnalysisScoreWindow
}

/// y is up. Radar vertices and sparkline samples both use this.
struct AnalysisChartPoint: Equatable {
    var x: Double
    var y: Double
}

enum AnalysisRadarLayout {
    static let vertexCount = 8
    static let scoreMaximum = 100
    /// Primary fill under the radar line. Stays inside 0.12...0.20. Not a second palette.
    static let fillOpacity = 0.16
    /// Grid rings at 25, 50, 75, and 100.
    static let ringFractions: [Double] = [0.25, 0.5, 0.75, 1]

    /// Unit vertex, clockwise from the top. Index 0 is 体力.
    static func unitVertex(index: Int) -> AnalysisChartPoint {
        let count = Double(vertexCount)
        let angle = Double.pi / 2 - (Double(index) * 2 * Double.pi / count)
        return AnalysisChartPoint(x: cos(angle), y: sin(angle))
    }

    /// Score 0 is the origin. Score 100 is the unit vertex. Values outside 0...100 clamp.
    static func point(index: Int, score: Int) -> AnalysisChartPoint {
        let clamped = min(scoreMaximum, max(0, score))
        let scale = Double(clamped) / Double(scoreMaximum)
        let unit = unitVertex(index: index)
        return AnalysisChartPoint(x: unit.x * scale, y: unit.y * scale)
    }

    /// `scores` follows `AnalysisScoreDimension.allCases`, clockwise from the top.
    static func polygon(scores: [Int]) -> [AnalysisChartPoint] {
        scores.enumerated().map { point(index: $0.offset, score: $0.element) }
    }
}

enum AnalysisSparklineLayout {
    static let axisMinimum = 0
    static let axisMaximum = 100

    /// x is 0...1 across `window`. y is 0...1 where 0 is the axis minimum and 1 is 100.
    /// Samples outside the window are left out. Scores outside 0...100 clamp onto the axis.
    static func normalized(samples: [AnalysisScoreSample], window: AnalysisScoreWindow) -> [AnalysisChartPoint] {
        let span = window.end.timeIntervalSince(window.start)
        guard span > 0 else { return [] }
        return samples.compactMap { sample in
            guard sample.date >= window.start, sample.date <= window.end else { return nil }
            let x = min(1, max(0, sample.date.timeIntervalSince(window.start) / span))
            let clamped = min(axisMaximum, max(axisMinimum, sample.score))
            let y = Double(clamped - axisMinimum) / Double(axisMaximum - axisMinimum)
            return AnalysisChartPoint(x: x, y: y)
        }
    }
}

enum AnalysisScorePlaceholder {
    /// The type is a stand-in. Callers should not treat `card(now:)` as a measured score.
    static let isFrameworkPlaceholder = true
    /// Hand-picked sample. Not the mean of the eight axes and not a load formula.
    static let compositeScore = 73
    static let sampleCount = 13

    /// Thirteen points from the start of the three-month window to `now`.
    /// Each line is a different shape so the radar is not a regular octagon and the
    /// sparklines are not flat. Still not derived from workouts.
    static let series: [AnalysisScoreDimension: [Int]] = [
        .stamina: [42, 45, 48, 52, 55, 58, 61, 64, 66, 69, 72, 75, 78],
        .strength: [70, 68, 66, 69, 73, 71, 67, 64, 68, 72, 74, 73, 71],
        .power: [38, 44, 72, 41, 49, 80, 46, 53, 76, 50, 43, 68, 62],
        .variety: [28, 31, 34, 36, 40, 43, 47, 49, 52, 55, 58, 61, 64],
        .technique: [84, 86, 85, 82, 79, 76, 80, 83, 87, 86, 84, 86, 88],
        .experience: [46, 48, 49, 51, 52, 54, 55, 57, 58, 60, 62, 64, 67],
        .will: [74, 68, 60, 52, 44, 40, 47, 55, 63, 69, 73, 75, 77],
        .recovery: [61, 74, 52, 70, 48, 66, 57, 73, 51, 69, 60, 76, 64]
    ]

    /// Stable sample for `now`. The same instant always returns the same card.
    /// There is no `workouts` argument: this does not read training records.
    static func card(now: Date = Date(), calendar: Calendar = AnalysisScoreCalendar.shanghai) -> AnalysisScoreCardModel {
        let window = AnalysisScoreWindow.lastThreeMonths(ending: now, calendar: calendar)
        let dates = sampleDates(in: window)
        let trends = AnalysisScoreDimension.allCases.map { dimension in
            let values = series[dimension] ?? Array(repeating: 0, count: sampleCount)
            let samples = zip(dates, values).map { AnalysisScoreSample(date: $0, score: $1) }
            return AnalysisScoreTrend(dimension: dimension, samples: samples)
        }
        var current: [AnalysisScoreDimension: Int] = [:]
        for trend in trends {
            current[trend.dimension] = trend.samples.last?.score ?? 0
        }
        return AnalysisScoreCardModel(
            isFrameworkPlaceholder: true,
            composite: compositeScore,
            current: current,
            trends: trends,
            window: window
        )
    }

    /// Current scores in radar order. A missing axis is 0 so the polygon still has eight vertices.
    static func orderedScores(_ current: [AnalysisScoreDimension: Int]) -> [Int] {
        AnalysisScoreDimension.allCases.map { current[$0] ?? 0 }
    }

    static func sampleDates(in window: AnalysisScoreWindow) -> [Date] {
        guard sampleCount > 1 else { return [window.end] }
        let span = window.end.timeIntervalSince(window.start)
        return (0..<sampleCount).map { index in
            if index == 0 { return window.start }
            if index == sampleCount - 1 { return window.end }
            let fraction = Double(index) / Double(sampleCount - 1)
            return window.start.addingTimeInterval(span * fraction)
        }
    }
}

/// Analysis page data. `window` selects training stats only.
struct AnalysisPageSnapshot {
    var stats: TrainingStats
    /// Placeholder score card. Ignores `window` and the workout list.
    var score: AnalysisScoreCardModel
}

enum AnalysisPageFrame {
    /// Changing `window` changes `stats` and leaves `score` on `AnalysisScorePlaceholder`.
    /// The score card does not read `workouts`.
    static func snapshot(
        workouts: [WorkoutRecord],
        window: StatsWindow,
        now: Date = Date()
    ) -> AnalysisPageSnapshot {
        AnalysisPageSnapshot(
            stats: RecordStats.make(workouts: workouts, window: window, now: now),
            score: AnalysisScorePlaceholder.card(now: now)
        )
    }
}
