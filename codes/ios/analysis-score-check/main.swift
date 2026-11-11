import Foundation

// swiftc codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/ZoneDwell.swift \
//   codes/ios/Shared/SampleLibrary.swift \
//   codes/ios/Shared/AnalysisScorePlaceholder.swift \
//   codes/ios/analysis-score-check/main.swift \
//   -o /tmp/analysis-score-check && /tmp/analysis-score-check

/// SampleLibrary's preset route names this. The check does not compile LiveSession.
enum MapOrigin {
    static let fallback = GeoPoint(latitude: 31.24, longitude: 121.49, altitude: 12, timestamp: nil)
}

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

func near(_ actual: Double, _ expected: Double, _ tolerance: Double, _ message: String) {
    check(abs(actual - expected) <= tolerance, "\(message): \(actual) !~ \(expected)")
}

let calendar = AnalysisScoreCalendar.shanghai

func shanghai(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

// MARK: - Eight axes, clockwise from the top

let titles = AnalysisScoreDimension.allCases.map(\.title)
check(
    titles == ["体力", "力量", "爆发", "多样", "技术", "经验", "意志", "恢复"],
    "radar axes stay in clockwise order \(titles)"
)
check(AnalysisScoreDimension.allCases.count == 8, "eight dimensions")
check(AnalysisScorePlaceholder.isFrameworkPlaceholder, "score card is marked as a framework placeholder")

let now = shanghai(2026, 11, 11, 16, 40)
let card = AnalysisScorePlaceholder.card(now: now)
check(card.isFrameworkPlaceholder, "card carries the placeholder mark")
check(card.composite == AnalysisScorePlaceholder.compositeScore, "composite is the stored sample, not a training formula")
check(card.composite > 0 && card.composite < 100, "composite sample is neither empty nor full")

let ordered = AnalysisScorePlaceholder.orderedScores(card.current)
check(ordered.count == 8, "one current score per axis")
check(ordered.allSatisfy { $0 > 0 && $0 < 100 }, "current scores stay off 0 and 100, \(ordered)")
check(Set(ordered).count >= 5, "current scores are not one repeated value \(ordered)")
check(
    ordered == AnalysisScoreDimension.allCases.map { AnalysisScorePlaceholder.series[$0]!.last! },
    "current score is the last sample of that axis, still not a workout calculation"
)

check(card.trends.map(\.dimension) == AnalysisScoreDimension.allCases, "trends follow the radar order")
check(card.trends.allSatisfy { $0.samples.count == AnalysisScorePlaceholder.sampleCount }, "each trend has the full sample")
for trend in card.trends {
    let scores = trend.samples.map(\.score)
    check(scores.allSatisfy { $0 > 0 && $0 < 100 }, "\(trend.dimension.title) samples stay inside 1...99")
    check((scores.max() ?? 0) - (scores.min() ?? 0) >= 8, "\(trend.dimension.title) line has a shape \(scores)")
    check(
        zip(trend.samples, trend.samples.dropFirst()).allSatisfy { $0.date < $1.date },
        "\(trend.dimension.title) samples move forward in time"
    )
}
let shapes = Set(card.trends.map { $0.samples.map(\.score) })
check(shapes.count == 8, "the eight lines are not copies of one series")

// MARK: - The sparkline window is the last three calendar months

let expectedStart = calendar.date(byAdding: .month, value: -3, to: now)!
check(card.window.end == now, "window ends at the anchor instant")
check(card.window.start == expectedStart, "window starts three calendar months earlier")
check(card.window.start != now.addingTimeInterval(-90 * 24 * 60 * 60), "three calendar months is not a fixed 90 days")

let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: card.window.start)
check(parts.year == 2026 && parts.month == 8 && parts.day == 11, "2026-11-11 minus three months is 2026-08-11, got \(parts)")
check(parts.hour == 16 && parts.minute == 40, "the window keeps the clock time")

let may31 = shanghai(2026, 5, 31, 8, 0)
let clamped = AnalysisScoreWindow.lastThreeMonths(ending: may31, calendar: calendar)
let clampedParts = calendar.dateComponents([.year, .month, .day], from: clamped.start)
check(
    clampedParts.year == 2026 && clampedParts.month == 2 && clampedParts.day == 28,
    "a short month clamps, May 31 minus three months is Feb 28, got \(clampedParts)"
)

for trend in card.trends {
    check(
        trend.samples.allSatisfy { $0.date >= card.window.start && $0.date <= card.window.end },
        "\(trend.dimension.title) samples stay inside the three-month window"
    )
    check(trend.samples.first?.date == card.window.start, "\(trend.dimension.title) starts on the window")
    check(trend.samples.last?.date == card.window.end, "\(trend.dimension.title) ends on the window")
}

let outside = AnalysisScoreSample(date: card.window.start.addingTimeInterval(-86_400), score: 40)
let inside = AnalysisScoreSample(date: card.window.start, score: 0)
let top = AnalysisScoreSample(date: card.window.end, score: 100)
let plotted = AnalysisSparklineLayout.normalized(samples: [outside, inside, top], window: card.window)
check(plotted.count == 2, "a day before the window is not drawn, count \(plotted.count)")
near(plotted[0].x, 0, 0.000_001, "first kept sample is the start of the window")
near(plotted[0].y, 0, 0.000_001, "score 0 sits on the bottom of a 0...100 axis")
near(plotted[1].x, 1, 0.000_001, "last sample is the end of the window")
near(plotted[1].y, 1, 0.000_001, "score 100 sits on the top of a 0...100 axis")

let midDate = card.window.start.addingTimeInterval(card.window.end.timeIntervalSince(card.window.start) / 2)
let mid = AnalysisSparklineLayout.normalized(
    samples: [AnalysisScoreSample(date: midDate, score: 50)],
    window: card.window
)
near(mid[0].x, 0.5, 0.000_001, "the middle of the window is the middle of the chart")
near(mid[0].y, 0.5, 0.000_001, "score 50 is halfway up the fixed axis")

// MARK: - Radar geometry follows the same clockwise order

check(AnalysisRadarLayout.vertexCount == 8, "radar has eight vertices")
check(AnalysisRadarLayout.fillOpacity >= 0.12 && AnalysisRadarLayout.fillOpacity <= 0.20, "radar fill stays a light primary")
check(AnalysisRadarLayout.ringFractions == [0.25, 0.5, 0.75, 1], "grid rings quarter the 100-point scale")

let topVertex = AnalysisRadarLayout.unitVertex(index: 0)
near(topVertex.x, 0, 0.000_001, "体力 is the top vertex")
near(topVertex.y, 1, 0.000_001, "体力 points up")
let upperRight = AnalysisRadarLayout.unitVertex(index: 1)
check(upperRight.x > 0 && upperRight.y > 0, "力量 is clockwise from 体力, in the upper right")

for index in 0..<AnalysisRadarLayout.vertexCount {
    let current = AnalysisRadarLayout.unitVertex(index: index)
    let next = AnalysisRadarLayout.unitVertex(index: (index + 1) % AnalysisRadarLayout.vertexCount)
    let cross = current.x * next.y - current.y * next.x
    check(cross < -0.5, "vertex \(index) steps clockwise, cross \(cross)")
    near(hypot(current.x, current.y), 1, 0.000_001, "unit vertex \(index) is on the ring")
}

let fullTop = AnalysisRadarLayout.point(index: 0, score: 100)
near(fullTop.x, 0, 0.000_001, "100 maps to the outer vertex")
near(fullTop.y, 1, 0.000_001, "100 reaches the top ring")
let halfTop = AnalysisRadarLayout.point(index: 0, score: 50)
near(halfTop.y, 0.5, 0.000_001, "50 is halfway to the ring")
let origin = AnalysisRadarLayout.point(index: 2, score: 0)
near(origin.x, 0, 0.000_001, "0 is the center")
near(origin.y, 0, 0.000_001, "0 has no radius")
let overScore = AnalysisRadarLayout.point(index: 2, score: 140)
near(overScore.x, 1, 0.000_001, "a score above 100 stays on the ring")
near(overScore.y, 0, 0.000_001, "爆发 is the right-hand vertex")

let samplePolygon = AnalysisRadarLayout.polygon(scores: ordered)
check(samplePolygon.count == 8, "the sample draws one vertex per axis")
check(
    zip(samplePolygon, ordered).allSatisfy { point, score in
        abs(hypot(point.x, point.y) - Double(score) / 100) < 0.000_001
    },
    "vertex radius is the axis score over 100"
)
check(
    Set(samplePolygon.map { hypot($0.x, $0.y) }).count >= 5,
    "the sample polygon is not a regular octagon"
)

// MARK: - The period control changes stats only

func workout(start: Date, meters: Double) -> WorkoutRecord {
    WorkoutRecord(
        id: UUID(),
        sport: .running,
        start: start,
        end: start.addingTimeInterval(1800),
        distanceMeters: meters,
        energyKilocalories: 120,
        averageHeartRate: 140,
        averageCadence: 170,
        elevationGainMeters: 20,
        route: [],
        splits: [],
        heartRate: [],
        cadenceSeries: [],
        paceSeries: [],
        stride: [],
        elevation: [],
        groundContact: [],
        power: [],
        origin: .apple,
        healthKitUUID: UUID().uuidString
    )
}

let workouts = [
    workout(start: shanghai(2026, 11, 11, 7, 0), meters: 5_000),
    workout(start: shanghai(2026, 11, 1, 7, 0), meters: 3_000),
    workout(start: shanghai(2026, 1, 15, 7, 0), meters: 2_000),
    workout(start: shanghai(2025, 6, 1, 7, 0), meters: 1_000)
]

let windows = StatsWindow.allCases
let snapshots = windows.map { window in
    AnalysisPageFrame.snapshot(workouts: workouts, window: window, now: now)
}
check(snapshots.count == 4, "week, month, year, and all")
let distances = snapshots.map(\.stats.distanceMeters)
check(
    distances == [5_000, 8_000, 10_000, 11_000],
    "each period keeps a different training total \(distances)"
)
check(snapshots.allSatisfy { $0.score == card }, "every period reads the same placeholder score card")

let empty = AnalysisPageFrame.snapshot(workouts: [], window: .week, now: now)
check(empty.stats.distanceMeters == 0, "a period with no workouts still has empty stats")
check(empty.score == card, "clearing workouts does not change the placeholder score")
check(empty.stats.distanceMeters != snapshots[0].stats.distanceMeters, "the week control still changes the stats card")

if failures.isEmpty {
    print("analysis-score-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
