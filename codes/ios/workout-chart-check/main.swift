import Foundation

// swiftc codes/ios/Shared/Models.swift codes/ios/Shared/SampleLibrary.swift \
//   codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/sky-wanderer/WorkoutChartMath.swift \
//   codes/ios/workout-chart-check/main.swift \
//   -o /tmp/workout-chart-check && /tmp/workout-chart-check

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

func series(_ values: [Double]) -> [SeriesPoint] {
    values.enumerated().map { SeriesPoint(second: Double($0.offset), value: $0.element) }
}

// MARK: - Plot every stored sample

let twoHundred = series((0..<200).map { Double($0) })
let plottedTwoHundred = WorkoutChartMath.plotSamples(twoHundred)
check(plottedTwoHundred.count == 200, "plot keeps 200 samples, above the old 90-point cap")
check(
    plottedTwoHundred.map(\.second) == twoHundred.map(\.second),
    "plot keeps every second when the series is already unique"
)

let aboveIngest = series((0..<800).map { Double($0 % 50) })
let plottedAboveIngest = WorkoutChartMath.plotSamples(aboveIngest)
check(plottedAboveIngest.count == 800, "plot does not reapply the 720 ingest cap")
check(
    zip(plottedAboveIngest, plottedAboveIngest.dropFirst()).allSatisfy { $0.second < $1.second },
    "plotted seconds stay strictly increasing"
)

// A 90-point stride skips these odd indexes. The default plot must still draw them.
var skippedByOldCap = series(Array(repeating: 40.0, count: 180))
skippedByOldCap[7] = SeriesPoint(second: 7, value: 241)
let oldStep = max(1, skippedByOldCap.count / 90)
let oldStride = Set(stride(from: 0, to: skippedByOldCap.count, by: oldStep))
check(!oldStride.contains(7), "fixture really is off the old 90-point stride")
let plottedSkipped = WorkoutChartMath.plotSamples(skippedByOldCap)
check(plottedSkipped.count == 180, "default plot keeps the sample the old cap would skip")
check(plottedSkipped.contains { $0.second == 7 && $0.value == 241 }, "default plot keeps the fastest pace sample")

// An explicit limit still thins, but the true min and max stay on the series.
var limited = series(Array(repeating: 10.0, count: 300))
limited[1] = SeriesPoint(second: 1, value: 1)
limited[2] = SeriesPoint(second: 2, value: 99)
let limitStep = max(1, limited.count / 90)
let limitStride = Set(stride(from: 0, to: limited.count, by: limitStep))
check(!limitStride.contains(1) && !limitStride.contains(2), "extrema sit off the 90-point stride")
let plottedLimited = WorkoutChartMath.plotSamples(limited, limit: 90)
check(plottedLimited.count <= 90, "explicit 90 cap is honored, count \(plottedLimited.count)")
check(plottedLimited.count >= 2, "capped series still draws a line")
check(plottedLimited.contains { $0.value == 1 }, "capped series keeps the minimum")
check(plottedLimited.contains { $0.value == 99 }, "capped series keeps the maximum")
check(
    zip(plottedLimited, plottedLimited.dropFirst()).allSatisfy { $0.second < $1.second },
    "capped seconds stay strictly increasing"
)

// uniqued keeps the first value at a second. The true minimum shares that second
// with a milder point, and the maximum is elsewhere, so both extrema can be drawn.
let collapsed = WorkoutChartMath.plotSamples([
    SeriesPoint(second: 0, value: 4),
    SeriesPoint(second: 5, value: 3),
    SeriesPoint(second: 5, value: 1),
    SeriesPoint(second: 9, value: 6)
])
check(collapsed.count == 3, "duplicate second collapses to one sample, count \(collapsed.count)")
check(
    collapsed.contains { $0.second == 5 && $0.value == 1 },
    "duplicate second keeps the minimum when the maximum is another sample"
)
check(collapsed.contains { $0.second == 9 && $0.value == 6 }, "collapsed series keeps the maximum")

let cleaned = WorkoutChartMath.plotSamples([
    SeriesPoint(second: 0, value: 4),
    SeriesPoint(second: .nan, value: 1),
    SeriesPoint(second: 1, value: .infinity),
    SeriesPoint(second: 2, value: 6),
    SeriesPoint(second: .infinity, value: 3)
])
check(cleaned.count == 2, "non-finite samples are dropped")
check(cleaned.map(\.value) == [4, 6], "finite samples stay in order \(cleaned.map(\.value))")

check(WorkoutChartMath.plotSamples([SeriesPoint(second: 0, value: 5)]).isEmpty, "one sample is not a line")
check(WorkoutChartMath.plotSamples([]).isEmpty, "empty series is not a line")

// The slow outlier stays on the series. The axis cap is separate.
let withOutlier = WorkoutChartMath.plotSamples(series([360, 3000, 360]))
check(withOutlier.contains { $0.value == 3000 }, "a 50'/km sample stays on the plotted series")

// MARK: - Pace axis

// 98 samples at 6'00", one true fastest, one ~50'/km outlier.
// The 95th percentile is 360. 1.75× the median is 630. The cap uses 630, not 3000.
var crowded = Array(repeating: 360.0, count: 100)
crowded[0] = 250
crowded[80] = 3000
let crowdedScale = WorkoutChartMath.paceScale(series(crowded))
near(crowdedScale.fastest, 250, 0.001, "pace domain uses the true fastest sample")
near(crowdedScale.slowCap, 630, 0.001, "slow cap is 1.75× the median when that is above the 95th percentile")
near(crowdedScale.domain.lowerBound, -630, 0.05, "outlier clips at the slow cap")
near(crowdedScale.domain.upperBound, -181.6, 0.05, "fast end keeps padding above the fastest pace")
check(crowdedScale.domain.contains(-250), "inverted domain includes the fastest pace")
check(-3000 < crowdedScale.domain.lowerBound, "50'/km is below the chart")
check(crowdedScale.domain.upperBound > crowdedScale.domain.lowerBound, "faster pace is the top of the axis")

// 1.75× the median would cut the 1000 cluster. The cap has to rise to the 95th percentile.
var wide = Array(repeating: 200.0, count: 60)
wide.append(contentsOf: Array(repeating: 1000.0, count: 35))
wide.append(contentsOf: Array(repeating: 3000.0, count: 5))
let wideScale = WorkoutChartMath.paceScale(series(wide))
near(wideScale.fastest, 200, 0.001, "wide series fastest")
near(wideScale.slowCap, 1000, 0.001, "slow cap is at least the 95th percentile")
near(wideScale.domain.lowerBound, -1000, 0.05, "95th percentile sits on the bottom when it is the cap")
check(wideScale.domain.contains(-200), "wide series includes the fastest pace")
check(wideScale.domain.contains(-1000), "wide series includes the 95th percentile")
check(-3000 < wideScale.domain.lowerBound, "tail beyond the 95th percentile clips")

// No outlier: the cap is the real slowest pace, and both ends keep the old padding.
let even = WorkoutChartMath.paceScale(series(Array(300...399).map(Double.init)))
near(even.fastest, 300, 0.001, "even series fastest")
near(even.slowCap, 399, 0.001, "even series does not invent a cap past the slowest sample")
near(even.domain.lowerBound, -416.82, 0.05, "even series pads the slow end")
near(even.domain.upperBound, -282.18, 0.05, "even series pads the fast end")
check(even.domain.contains(-300) && even.domain.contains(-399), "even series shows every pace")

let ignored = WorkoutChartMath.paceScale(series([-10, 0, 3600, .nan, .infinity, 300, 400]))
near(ignored.fastest, 300, 0.001, "pace domain ignores non-positive, non-finite, and 3600")
near(ignored.slowCap, 400, 0.001, "3600 is outside the existing pace filter")
check(ignored.domain.contains(-300) && ignored.domain.contains(-400), "valid paces stay on the axis")

let onlyCeiling = WorkoutChartMath.paceScale(series([300, 3600]))
near(onlyCeiling.fastest, 300, 0.001, "a lone valid pace is the fast end")
near(onlyCeiling.slowCap, 300, 0.001, "3600 does not become the slow end")

let almostCeiling = WorkoutChartMath.paceScale(series([300, 3599]))
near(almostCeiling.fastest, 300, 0.001, "3599 is inside the pace filter")
near(almostCeiling.slowCap, 3599, 0.001, "two valid paces are not treated as an outlier")
check(almostCeiling.domain.contains(-300) && almostCeiling.domain.contains(-3599), "both valid paces are on the axis")

let one = WorkoutChartMath.paceScale(series([300]))
near(one.fastest, 300, 0.001, "single pace fastest")
near(one.slowCap, 300, 0.001, "single pace cap")
near(one.domain.lowerBound, -315, 0.05, "single pace slow padding")
near(one.domain.upperBound, -285, 0.05, "single pace fast padding")
check(one.domain.contains(-300), "single pace is on the axis")

let empty = WorkoutChartMath.paceScale([])
near(empty.fastest, 300, 0.001, "empty pace axis falls back to 5'00\"")
near(empty.slowCap, 600, 0.001, "empty pace axis falls back to 10'00\"")
near(empty.domain.lowerBound, -654, 0.05, "empty pace axis slow padding")
near(empty.domain.upperBound, -246, 0.05, "empty pace axis fast padding")
check(empty.domain.contains(-300) && empty.domain.contains(-600), "empty pace axis covers the fallback")

// Fastest sample is off a 90-point stride, and a slow outlier is present.
var hiddenFast = series(Array(repeating: 400.0, count: 180))
hiddenFast[7] = SeriesPoint(second: 7, value: 241)
hiddenFast[9] = SeriesPoint(second: 9, value: 3000)
let hiddenScale = WorkoutChartMath.paceScale(hiddenFast)
near(hiddenScale.fastest, 241, 0.001, "domain reads the fastest pace from the full series")
check(hiddenScale.domain.contains(-241), "domain includes a fastest pace the old downsample would skip")
check(-3000 < hiddenScale.domain.lowerBound, "domain still caps the slow outlier")
check(hiddenScale.slowCap < 1000, "slow cap stays near the body of the series, cap \(hiddenScale.slowCap)")

if failures.isEmpty {
    print("workout-chart-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
