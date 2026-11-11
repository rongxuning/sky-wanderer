import Foundation

// swiftc -swift-version 5 codes/ios/Shared/Models.swift codes/ios/Shared/SampleLibrary.swift \
//   codes/ios/Shared/TrainingEstimate.swift codes/ios/Shared/ZoneDwell.swift \
//   codes/ios/training-estimate-check/main.swift \
//   -o /tmp/training-estimate-check && /tmp/training-estimate-check

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

let now = Date(timeIntervalSince1970: 1_800_000_000)

func workout(
    sport: SportKind = .running,
    minutes: Double,
    averageHeartRate: Double,
    heartRate: [SeriesPoint] = [],
    hoursAgo: Double = 1,
    elapsedExtra: TimeInterval = 0
) -> WorkoutRecord {
    let moving = minutes * 60
    let start = now.addingTimeInterval(-hoursAgo * 3600)
    return WorkoutRecord(
        id: UUID(),
        sport: sport,
        start: start,
        end: start.addingTimeInterval(moving + elapsedExtra),
        distanceMeters: 1000,
        energyKilocalories: 1,
        averageHeartRate: averageHeartRate,
        averageCadence: 0,
        elevationGainMeters: 0,
        route: [],
        splits: [],
        heartRate: heartRate,
        cadenceSeries: [],
        paceSeries: [],
        stride: [],
        elevation: [],
        groundContact: [],
        power: [],
        origin: .apple,
        healthKitUUID: nil,
        trainingDurationSeconds: moving
    )
}

func load(
    minutes: Double,
    averageHeartRate: Double,
    heartRate: [SeriesPoint] = []
) -> Int {
    TrainingEstimate.sessionLoad(
        trainingDuration: minutes * 60,
        heartRate: heartRate,
        averageHeartRate: averageHeartRate
    )
}

func edwards(_ shares: [ZoneShare]) -> Int {
    let raw = shares.enumerated().reduce(0.0) { partial, item in
        partial + item.element.seconds / 60 * Double(item.offset + 1)
    }
    return Int(raw.rounded())
}

// MARK: - Average heart rate only

// 41 min 23 s at 137 bpm is entirely Z3. round((41 + 23/60) × 3) = 124.
let fortyOne = (41.0 * 60 + 23) / 60
check(load(minutes: fortyOne, averageHeartRate: 137) == 124, "41m23s at 137 bpm is Edwards 124")
check(
    workout(minutes: fortyOne, averageHeartRate: 137).sessionLoad == 124,
    "record load uses training minutes and the stored average"
)
check(
    workout(sport: .hiking, minutes: fortyOne, averageHeartRate: 137).sessionLoad
        == workout(sport: .running, minutes: fortyOne, averageHeartRate: 137).sessionLoad,
    "hiking and running share one load for the same heart-rate time"
)

check(load(minutes: 60, averageHeartRate: 0) == 0, "no heart rate is 0")
check(load(minutes: 60, averageHeartRate: -10) == 0, "negative heart rate is 0")
check(load(minutes: 60, averageHeartRate: .nan) == 0, "non-finite heart rate is 0")
check(load(minutes: 0, averageHeartRate: 137) == 0, "no training time and no series is 0")
check(
    load(minutes: 60, averageHeartRate: 0, heartRate: [SeriesPoint(second: 0, value: 0)]) == 0,
    "a non-positive series is not usable heart rate"
)

check(
    ZoneDwell.heartBands.map(\.name) == ["有氧基础", "有氧耐力", "乳酸阈值", "速度耐力", "冲刺能力"],
    "heart band names stay with the detail chart"
)
check(
    ZoneDwell.heartBands.map(\.range) == ["<114", "114–132", "133–151", "152–170", "≥171"],
    "heart band ranges stay with the detail chart"
)
check(ZoneDwell.heartZone(0) == 1, "zero bpm is still zone 1")
check(ZoneDwell.heartZone(0.0005) == 1, "bpm under the chart floor is still zone 1")
check(ZoneDwell.heartBands[0].contains(0.0005) == false, "the chart band still starts at 0.001")

// Zone of the average, one training minute each. Boundaries match ZoneScale.heart.
check(load(minutes: 1, averageHeartRate: 113.9) == 1, "113.9 bpm is Z1")
check(load(minutes: 1, averageHeartRate: 114) == 2, "114 bpm is Z2")
check(load(minutes: 1, averageHeartRate: 132.9) == 2, "132.9 bpm stays Z2")
check(load(minutes: 1, averageHeartRate: 133) == 3, "133 bpm is Z3")
check(load(minutes: 1, averageHeartRate: 151.9) == 3, "151.9 bpm stays Z3")
check(load(minutes: 1, averageHeartRate: 152) == 4, "152 bpm is Z4")
check(load(minutes: 1, averageHeartRate: 170.9) == 4, "170.9 bpm stays Z4")
check(load(minutes: 1, averageHeartRate: 171) == 5, "171 bpm is Z5")
check(load(minutes: 10.0 / 60, averageHeartRate: 180) == 1, "10s in Z5 rounds to 1")
check(load(minutes: 20.0 / 60, averageHeartRate: 100) == 0, "20s in Z1 rounds to 0")

// A longer elapsed time does not replace the stored training minutes.
let pausedAverage = workout(minutes: 5, averageHeartRate: 150, elapsedExtra: 600)
check(pausedAverage.sessionLoad == 15, "average-only load uses training minutes, not the pause")
check(pausedAverage.elapsedDuration == 900, "elapsed span still includes the pause")

// MARK: - Series zone time

// Gaps of 30s stay inside the pause rule, so each interval is the zone of its start sample.
// Z1 120s, Z2 60s, Z3 60s, Z4 30s, Z5 60s → 2+2+3+2+5 = 14.
let mixed: [SeriesPoint] = [
    SeriesPoint(second: 0, value: 100),
    SeriesPoint(second: 30, value: 100),
    SeriesPoint(second: 60, value: 100),
    SeriesPoint(second: 90, value: 100),
    SeriesPoint(second: 120, value: 120),
    SeriesPoint(second: 150, value: 120),
    SeriesPoint(second: 180, value: 140),
    SeriesPoint(second: 210, value: 140),
    SeriesPoint(second: 240, value: 160),
    SeriesPoint(second: 270, value: 180),
    SeriesPoint(second: 300, value: 180),
    SeriesPoint(second: 330, value: 180)
]
let mixedShares = ZoneDwell.shares(points: mixed, bands: ZoneDwell.heartBands)
near(mixedShares[0].seconds, 120, 0.001, "mixed Z1 seconds")
near(mixedShares[1].seconds, 60, 0.001, "mixed Z2 seconds")
near(mixedShares[2].seconds, 60, 0.001, "mixed Z3 seconds")
near(mixedShares[3].seconds, 30, 0.001, "mixed Z4 seconds")
near(mixedShares[4].seconds, 60, 0.001, "mixed Z5 seconds")
check(edwards(mixedShares) == 14, "known zone minutes are Edwards 14")
check(load(minutes: 60, averageHeartRate: 180, heartRate: mixed) == 14, "series load uses those zone minutes")
check(
    load(minutes: 60, averageHeartRate: 180, heartRate: mixed)
        == edwards(ZoneDwell.shares(points: mixed, bands: ZoneDwell.heartBands)),
    "session load and the zone-card shares stay on the same seconds"
)
check(
    workout(sport: .hiking, minutes: 60, averageHeartRate: 180, heartRate: mixed).sessionLoad
        == workout(sport: .running, minutes: 60, averageHeartRate: 180, heartRate: mixed).sessionLoad,
    "hiking and running match on the same series"
)

// 60s of Z1 from the series. The average would have put the whole hour in Z5.
let shortZ1 = [
    SeriesPoint(second: 0, value: 100),
    SeriesPoint(second: 30, value: 100),
    SeriesPoint(second: 60, value: 100)
]
check(
    load(minutes: 60, averageHeartRate: 180, heartRate: shortZ1) == 1,
    "a usable series wins over the average and over training minutes outside it"
)

// A 120s hole is a pause when any other gap is within 30s. Counted time is 60s of Z1.
let withPause = [
    SeriesPoint(second: 0, value: 110),
    SeriesPoint(second: 30, value: 110),
    SeriesPoint(second: 150, value: 110),
    SeriesPoint(second: 180, value: 110)
]
check(load(minutes: 10, averageHeartRate: 170, heartRate: withPause) == 1, "a pause gap is left out of zone time")
near(
    ZoneDwell.shares(points: withPause, bands: ZoneDwell.heartBands)[0].seconds,
    60,
    0.001,
    "pause shares match the load's Z1 minute"
)

// Every gap is past 30s, so the thinned-series rule applies: median 40s, keep up to 60s, drop the 120s hole.
let thinnedHole = [
    SeriesPoint(second: 0, value: 140),
    SeriesPoint(second: 40, value: 140),
    SeriesPoint(second: 80, value: 140),
    SeriesPoint(second: 200, value: 140)
]
let holeShares = ZoneDwell.shares(points: thinnedHole, bands: ZoneDwell.heartBands)
near(holeShares[2].seconds, 80, 0.001, "thinned series drops the long hole")
check(holeShares.reduce(0) { $0 + $1.seconds } == 80, "thinned hole keeps 80s")
check(load(minutes: 30, averageHeartRate: 100, heartRate: thinnedHole) == 4, "80s of Z3 is Edwards 4")

// Thinned series that crosses bands is split on the same edges as the chart stroke.
let crossed = [
    SeriesPoint(second: 0, value: 100),
    SeriesPoint(second: 100, value: 180),
    SeriesPoint(second: 200, value: 100)
]
let crossedShares = ZoneDwell.shares(points: crossed, bands: ZoneDwell.heartBands)
near(crossedShares[0].seconds, 35, 0.001, "crossed Z1")
near(crossedShares[1].seconds, 47.5, 0.001, "crossed Z2")
near(crossedShares[2].seconds, 47.5, 0.001, "crossed Z3")
near(crossedShares[3].seconds, 47.5, 0.001, "crossed Z4")
near(crossedShares[4].seconds, 22.5, 0.001, "crossed Z5")
check(load(minutes: 1, averageHeartRate: 100, heartRate: crossed) == edwards(crossedShares), "crossed load matches shares")
check(edwards(crossedShares) == 10, "crossed zones round to Edwards 10")

// The chart drops non-positive samples before shares. A leading zero must not open the thinned-series path.
let leadingZero = [
    SeriesPoint(second: 0, value: 0),
    SeriesPoint(second: 30, value: 140),
    SeriesPoint(second: 90, value: 140)
]
let positiveOnly = leadingZero.filter { $0.value > 0 }
check(
    load(minutes: 10, averageHeartRate: 100, heartRate: leadingZero)
        == edwards(ZoneDwell.shares(points: positiveOnly, bands: ZoneDwell.heartBands)),
    "non-positive samples stay out of zone time"
)
check(load(minutes: 10, averageHeartRate: 100, heartRate: leadingZero) == 3, "the remaining Z3 minute is Edwards 3")

// One sample cannot make zone time, so the average still covers the training minutes.
check(
    load(minutes: fortyOne, averageHeartRate: 137, heartRate: [SeriesPoint(second: 4, value: 137)]) == 124,
    "one heart-rate sample falls back to the average"
)
let oneSample = workout(minutes: 1, averageHeartRate: 137, heartRate: [SeriesPoint(second: 1, value: 100)])
check(oneSample.resolvedAverageHeartRate == 100, "one sample replaces the stored average")
check(oneSample.sessionLoad == 1, "that resolved average is the zone for the training minute")

// MARK: - Seven-day rest hints, scaled ×3 for Edwards loads

func summary(_ minutes: [Double], extraOld: Double = 0) -> TrainingEstimateSummary {
    var rows = minutes.enumerated().map { index, value in
        workout(minutes: value, averageHeartRate: 100, hoursAgo: Double(index) + 1)
    }
    if extraOld > 0 {
        rows.append(workout(minutes: extraOld, averageHeartRate: 100, hoursAgo: 8 * 24))
    }
    return TrainingEstimate.summarize(workouts: rows, now: now)
}

let quiet = summary([])
check(quiet.recentLoad == 0 && quiet.reserve == 100 && quiet.restHint == "可以正常训练", "empty week is full reserve")

let under = summary([599])
check(under.recentLoad == 599 && under.reserve == 61 && under.restHint == "可以正常训练", "599 stays trainable")

let day = summary([600])
check(day.recentLoad == 600 && day.reserve == 60 && day.restHint == "建议休息 24 小时", "600 suggests 24 hours")

let underTwo = summary([1049])
check(underTwo.recentLoad == 1049 && underTwo.reserve == 31 && underTwo.restHint == "建议休息 24 小时", "1049 stays at 24 hours")

let twoDays = summary([1050])
check(twoDays.recentLoad == 1050 && twoDays.reserve == 30 && twoDays.restHint == "建议休息 48 小时", "1050 suggests 48 hours")

let spent = summary([1500])
check(spent.reserve == 0 && spent.restHint == "建议休息 48 小时", "reserve floors at 0")

let windowed = summary([100], extraOld: 5000)
check(windowed.recentLoad == 100 && windowed.reserve == 94, "load older than 7 days is outside the window")

// Training score stays on heart rate / 180. Edwards load does not replace it.
let scored = RecordStats.make(
    workouts: [workout(minutes: fortyOne, averageHeartRate: 137)],
    window: .all,
    now: now
)
near(scored.trainingScore, (137 / 180) * 100, 0.001, "training score still uses heart rate / 180")
check(scored.totalSessionLoad == 124, "stats total follows the Edwards session load")
check(scored.averageSessionLoad == 124, "stats average follows the Edwards session load")

if failures.isEmpty {
    print("training-estimate-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
