import Foundation

// swiftc codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/ZoneDwell.swift \
//   codes/ios/Shared/SampleLibrary.swift codes/ios/Shared/HealthSeries.swift \
//   codes/ios/Shared/Formatting.swift codes/ios/Shared/Database.swift \
//   codes/ios/Shared/AccountIdentity.swift \
//   codes/ios/health-series-check/main.swift -o /tmp/health-series-check && /tmp/health-series-check

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

func near(_ actual: Double, _ expected: Double, tolerance: Double, _ message: String) {
    check(abs(actual - expected) <= tolerance, "\(message): \(actual) !~ \(expected)")
}

let start = Date(timeIntervalSince1970: 1_700_000_000)
let end = start.addingTimeInterval(900)

func sample(_ startOffset: TimeInterval, _ endOffset: TimeInterval, _ value: Double) -> HealthQuantitySample {
    HealthQuantitySample(
        start: start.addingTimeInterval(startOffset),
        end: start.addingTimeInterval(endOffset),
        value: value
    )
}

let heart = HealthSeries.instantaneous(
    [
        sample(0, 10, 120),
        sample(5, 10, 130),
        sample(20, 30, .nan),
        sample(40, 50, 0),
        sample(40, 50, 140)
    ],
    workoutStart: start,
    workoutEnd: end
)
check(heart.count == 2, "heart keeps two finite points, got \(heart)")
check(heart.first?.second == 10 && heart.first?.value == 130, "same-second heart keeps the later sample")
check(heart.last?.second == 50 && heart.last?.value == 140, "later heart sample kept")

let contact = HealthSeries.groundContactMilliseconds(
    [sample(0, 5, 0.228), sample(10, 15, 0)],
    workoutStart: start,
    workoutEnd: end
)
check(contact.count == 1, "ground contact keeps the positive sample, got \(contact)")
near(contact.first?.value ?? 0, 228, tolerance: 0.01, "ground contact seconds become milliseconds")

let oscillation = HealthSeries.verticalOscillationMillimeters(
    [sample(0, 5, 0.084), sample(8, 12, 0.091)],
    workoutStart: start,
    workoutEnd: end
)
check(oscillation.count == 2, "vertical oscillation has two points")
near(oscillation[0].value, 84, tolerance: 0.01, "84 mm")
near(oscillation[1].value, 91, tolerance: 0.01, "91 mm")

let cadence = HealthSeries.cadence(
    stepSamples: [
        sample(0, 10, 20),
        sample(10, 20, 1),
        sample(20, 30, 18)
    ],
    workoutStart: start,
    workoutEnd: end
)
check(cadence.count == 2, "cadence drops windows outside the walking band, got \(cadence)")
near(cadence[0].value, 120, tolerance: 0.01, "120 spm")
check(cadence[0].second == 10, "cadence is stamped at the window end")
near(cadence[1].value, 108, tolerance: 0.01, "108 spm")

func northRoute(count: Int, stepMeters: Double, stepSeconds: Double, firstOffset: TimeInterval, altitude: Double) -> [GeoPoint] {
    (0..<count).map { index in
        GeoPoint(
            latitude: 31.24 + (Double(index) * stepMeters) / 111_320,
            longitude: 121.49,
            altitude: altitude + Double(index),
            timestamp: start.addingTimeInterval(firstOffset + Double(index) * stepSeconds)
        )
    }
}

let route = northRoute(count: 26, stepMeters: 100, stepSeconds: 30, firstOffset: 0, altitude: 20)
let hearts = [
    SeriesPoint(second: 100, value: 150),
    SeriesPoint(second: 200, value: 160),
    SeriesPoint(second: 400, value: 170),
    SeriesPoint(second: 700, value: 180)
]
let cadences = [
    SeriesPoint(second: 100, value: 170),
    SeriesPoint(second: 400, value: 174),
    SeriesPoint(second: 700, value: 168)
]
let tracked = HealthSeries.track(
    route: route,
    distanceSamples: [sample(0, 60, 50)],
    workoutStart: start,
    workoutEnd: end,
    referenceDistanceMeters: 2500,
    heartRate: hearts,
    cadence: cadences
)
check(tracked.pace.count >= 2, "route yields a pace series, got \(tracked.pace.count)")
near(tracked.pace[0].value, 300, tolerance: 2, "route pace")
check(tracked.pace[0].second > 20, "pace second is after the workout start")
check(tracked.splits.count == 3, "two full kilometers and a partial, got \(tracked.splits.count)")
check(tracked.splits.dropLast().allSatisfy { !$0.partial }, "full splits are not partial")
check(tracked.splits.last?.partial == true, "last split is partial")
near(tracked.splits.last?.distanceMeters ?? 0, 500, tolerance: 5, "partial split stores the leftover distance")
check((tracked.splits.last?.durationSeconds ?? 0) > 30, "partial split stores a duration")
check(tracked.splits.last?.listedDistanceText != "未满", "partial distance is not 未满")
check(tracked.splits.last?.listedTimeText != "—", "partial time is not a dash")
near(tracked.splits[0].paceSecPerKm, 300, tolerance: 2, "first split pace")
near(tracked.splits[0].heartRate, 155, tolerance: 0.01, "first split heart")
near(tracked.splits[0].cadence, 170, tolerance: 0.01, "first split cadence")
near(tracked.splits[1].heartRate, 170, tolerance: 0.01, "second split heart")
near(tracked.splits[2].heartRate, 180, tolerance: 0.01, "partial split heart")
check(tracked.elevation.count >= 2, "elevation comes from the route")
check(tracked.elevation.first?.second == 0, "elevation starts at the workout start")
near(tracked.elevation.first?.value ?? 0, 20, tolerance: 0.01, "first altitude")
check((tracked.elevation.last?.value ?? 0) > 40, "altitude rises along the route")

let shifted = HealthSeries.track(
    route: northRoute(count: 8, stepMeters: 100, stepSeconds: 30, firstOffset: 20, altitude: 12),
    distanceSamples: [],
    workoutStart: start,
    workoutEnd: end,
    referenceDistanceMeters: 700,
    heartRate: [],
    cadence: []
)
check((shifted.pace.first?.second ?? 0) >= 50, "pace offset includes the delay before the first fix, got \(shifted.pace.first?.second ?? -1)")
check((shifted.elevation.first?.second ?? -1) == 20, "elevation offset is from the workout start")

let fromDistance = HealthSeries.track(
    route: [
        GeoPoint(latitude: 31.24, longitude: 121.49, altitude: 8, timestamp: nil),
        GeoPoint(latitude: 31.25, longitude: 121.49, altitude: 18, timestamp: nil)
    ],
    distanceSamples: [
        sample(0, 60, 200),
        sample(60, 120, 200),
        sample(120, 180, 200)
    ],
    workoutStart: start,
    workoutEnd: end,
    referenceDistanceMeters: 600,
    heartRate: [],
    cadence: []
)
check(fromDistance.pace.count >= 2, "distance samples yield pace when the route has no timestamps")
near(fromDistance.pace[0].value, 300, tolerance: 1, "distance-sample pace")
check(fromDistance.splits.count == 1 && fromDistance.splits[0].partial, "short distance track is one partial split")
check(fromDistance.elevation.count == 2, "untimed route still supplies elevation")
check(fromDistance.elevation[0].second == 0 && fromDistance.elevation[1].second == 900, "untimed elevation spans the workout")

let cumulative = HealthSeries.track(
    route: [],
    distanceSamples: [
        sample(0, 60, 200),
        sample(60, 120, 400),
        sample(120, 180, 600)
    ],
    workoutStart: start,
    workoutEnd: end,
    referenceDistanceMeters: 600,
    heartRate: [],
    cadence: []
)
near(cumulative.pace.first?.value ?? 0, 300, tolerance: 1, "cumulative distance samples are differenced")
check(cumulative.splits.count == 1 && cumulative.splits[0].partial, "600 m is a partial split")

let prefersRoute = HealthSeries.track(
    route: route,
    distanceSamples: [sample(0, 10, 500), sample(10, 20, 500)],
    workoutStart: start,
    workoutEnd: end,
    referenceDistanceMeters: 2500,
    heartRate: [],
    cadence: []
)
near(prefersRoute.pace[0].value, 300, tolerance: 2, "a usable route wins over distance samples")
near(prefersRoute.splits[0].durationSeconds, 300, tolerance: 2, "splits stay on the route when distance samples miss the official total")
check(prefersRoute.distanceProgress.isEmpty, "a distance series far from the official total is not stored")

func makeWorkout(
    id: UUID = UUID(),
    origin: WorkoutOrigin = .apple,
    healthKitUUID: String? = "health-1",
    averageCadence: Double = 0,
    splits: [KilometerSplit] = [],
    heartRate: [SeriesPoint] = [],
    cadenceSeries: [SeriesPoint] = [],
    paceSeries: [SeriesPoint] = [],
    stride: [SeriesPoint] = [],
    elevation: [SeriesPoint] = [],
    groundContact: [SeriesPoint] = [],
    power: [SeriesPoint] = [],
    verticalOscillation: [SeriesPoint] = []
) -> WorkoutRecord {
    WorkoutRecord(
        id: id,
        sport: .running,
        start: start,
        end: end,
        distanceMeters: 2500,
        energyKilocalories: 180,
        averageHeartRate: 150,
        averageCadence: averageCadence,
        elevationGainMeters: 40,
        route: route,
        splits: splits,
        heartRate: heartRate,
        cadenceSeries: cadenceSeries,
        paceSeries: paceSeries,
        stride: stride,
        elevation: elevation,
        groundContact: groundContact,
        power: power,
        verticalOscillation: verticalOscillation,
        origin: origin,
        healthKitUUID: healthKitUUID
    )
}

let liveHeart = [SeriesPoint(second: 1, value: 151), SeriesPoint(second: 2, value: 152)]
let importedHeart = [SeriesPoint(second: 3, value: 140), SeriesPoint(second: 4, value: 141)]
let importedPace = [SeriesPoint(second: 30, value: 310), SeriesPoint(second: 60, value: 300)]
let existing = makeWorkout(
    heartRate: liveHeart,
    paceSeries: [],
    verticalOscillation: []
)
let imported = makeWorkout(
    id: UUID(),
    averageCadence: 172,
    splits: tracked.splits,
    heartRate: importedHeart,
    cadenceSeries: cadences,
    paceSeries: importedPace,
    stride: [SeriesPoint(second: 1, value: 1.1), SeriesPoint(second: 2, value: 1.2)],
    elevation: tracked.elevation,
    groundContact: contact,
    power: [SeriesPoint(second: 1, value: 240), SeriesPoint(second: 2, value: 250)],
    verticalOscillation: oscillation
)
let filled = WorkoutImport.merging(existing, with: imported)
check(filled.id == existing.id, "merge keeps the stored row")
check(filled.heartRate == liveHeart, "non-empty heart series stays")
check(filled.paceSeries == importedPace, "empty pace series is filled")
check(filled.splits == tracked.splits, "empty splits are filled")
check(filled.verticalOscillation == oscillation, "empty vertical oscillation is filled")
check(filled.averageCadence == 172, "missing cadence scalar is filled")
check(filled.distanceMeters == existing.distanceMeters, "merge does not rewrite summary scalars")

var withCurve = imported
withCurve.distanceProgress = [
    SeriesPoint(second: 0, value: 0),
    SeriesPoint(second: 30, value: 100)
]
withCurve.pauseIntervals = [WorkoutPause(startSecond: 5, endSecond: 12)]
let gained = WorkoutImport.merging(existing, with: withCurve)
check(gained.distanceProgress.count == 2, "merge stores official distance progress")
check(gained.pauseIntervals.count == 1 && gained.pauseIntervals[0].endSecond == 12, "merge stores pause intervals")
let keptCurve = WorkoutImport.merging(gained, with: makeWorkout(healthKitUUID: "health-1", averageCadence: 0))
check(keptCurve.distanceProgress.count == 2, "blank import does not clear distance progress")
check(keptCurve.pauseIntervals.count == 1, "blank import does not clear pauses")
var replacement = withCurve
replacement.distanceProgress = [
    SeriesPoint(second: 1, value: 5),
    SeriesPoint(second: 2, value: 6),
    SeriesPoint(second: 3, value: 7)
]
let alreadyCurved = WorkoutImport.merging(gained, with: replacement)
check(alreadyCurved.distanceProgress.count == 2, "merge keeps distance progress already stored")

let blank = makeWorkout(healthKitUUID: "health-1", averageCadence: 0)
let richer = makeWorkout(
    averageCadence: 168,
    heartRate: liveHeart,
    paceSeries: importedPace,
    verticalOscillation: oscillation
)
let kept = WorkoutImport.merging(richer, with: blank)
check(kept.heartRate == liveHeart, "blank import does not clear heart")
check(kept.paceSeries == importedPace, "blank import does not clear pace")
check(kept.verticalOscillation == oscillation, "blank import does not clear vertical oscillation")
check(kept.averageCadence == 168, "blank import does not clear cadence")

let withSeriesCadence = makeWorkout(
    averageCadence: 0,
    cadenceSeries: [SeriesPoint(second: 1, value: 170), SeriesPoint(second: 2, value: 174)]
)
let otherCadence = makeWorkout(averageCadence: 90, cadenceSeries: [SeriesPoint(second: 1, value: 90)])
let cadenceKept = WorkoutImport.merging(withSeriesCadence, with: otherCadence)
check(cadenceKept.averageCadence == 0, "resolved cadence blocks a scalar overwrite")
check(cadenceKept.cadenceSeries == withSeriesCadence.cadenceSeries, "non-empty cadence series stays")

var rows = [
    existing,
    makeWorkout(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, origin: .sample, healthKitUUID: "seed")
]
WorkoutImport.merge([imported], into: &rows)
check(
    rows.contains { $0.id == existing.id && $0.paceSeries == importedPace && $0.heartRate == liveHeart },
    "array merge fills empty series and keeps heart"
)
check(rows.allSatisfy { !SampleLibrary.isSeededWorkout($0) }, "merge still drops seeded workouts")
check(!rows.contains { $0.id == imported.id }, "existing uuid is updated in place")

var knownTraining = makeWorkout(averageCadence: 180)
knownTraining.distanceMeters = 1000
knownTraining.trainingDurationSeconds = 300
near(knownTraining.trainingDuration, 300, tolerance: 0.001, "stored training duration is used")
near(knownTraining.averagePaceSecPerKm, 300, tolerance: 0.001, "pace uses training time")
near(
    knownTraining.averageStrideMeters,
    (1000 / 300) / (180 / 60),
    tolerance: 0.001,
    "derived stride uses training pace"
)
check(
    knownTraining.sessionLoad == TrainingEstimate.sessionLoad(
        trainingDuration: 300,
        heartRate: knownTraining.heartRate,
        averageHeartRate: 150
    ),
    "load uses training time"
)
check(
    knownTraining.sessionLoad != TrainingEstimate.sessionLoad(
        trainingDuration: knownTraining.elapsedDuration,
        heartRate: knownTraining.heartRate,
        averageHeartRate: 150
    ),
    "load is not the elapsed load"
)
var tooLong = makeWorkout()
tooLong.trainingDurationSeconds = 10_000
check(tooLong.trainingDuration == tooLong.elapsedDuration, "training longer than elapsed falls back")
var unknownTraining = makeWorkout()
check(unknownTraining.trainingDurationSeconds == 0, "new records default training duration to unknown")
check(unknownTraining.trainingDuration == 900, "unknown training duration falls back to elapsed")
near(unknownTraining.averagePaceSecPerKm, 360, tolerance: 0.001, "unknown training time keeps elapsed pace")

var keptTraining = makeWorkout()
keptTraining.trainingDurationSeconds = 400
keptTraining.conditions = WorkoutConditions(temperatureCelsius: 10, weatherReady: true)
var importedTraining = makeWorkout()
importedTraining.trainingDurationSeconds = 800
let keptDuration = WorkoutImport.merging(keptTraining, with: importedTraining)
check(keptDuration.trainingDurationSeconds == 400, "merge does not replace training duration")
check(keptDuration.conditions?.temperatureCelsius == 10, "merge keeps cached weather")
let filledDuration = WorkoutImport.merging(makeWorkout(), with: importedTraining)
check(filledDuration.trainingDurationSeconds == 800, "merge fills an unknown training duration")
var tooLongImport = makeWorkout()
tooLongImport.trainingDurationSeconds = 10_000
let ignored = WorkoutImport.merging(makeWorkout(), with: tooLongImport)
check(ignored.trainingDurationSeconds == 0, "merge skips a training duration longer than elapsed")
var blankTraining = makeWorkout()
blankTraining.trainingDurationSeconds = 0
let notCleared = WorkoutImport.merging(keptTraining, with: blankTraining)
check(notCleared.trainingDurationSeconds == 400, "blank import does not clear training duration")

let paced = RecordStats.make(workouts: [knownTraining], window: .all, now: knownTraining.start)
near(paced.averagePaceSecPerKm, 300, tolerance: 0.001, "stats pace uses training time")
check(paced.totalSessionLoad == Double(knownTraining.sessionLoad), "stats load uses training load")

let legacy = """
{"id":"11111111-1111-1111-1111-111111111111","sport":"running","start":"2026-01-01T00:00:00Z","end":"2026-01-01T00:10:00Z","distanceMeters":1000,"energyKilocalories":50,"averageHeartRate":140,"averageCadence":170,"elevationGainMeters":12,"route":[],"splits":[],"heartRate":[{"second":1,"value":140},{"second":2,"value":142}],"cadenceSeries":[],"paceSeries":[],"stride":[],"elevation":[],"groundContact":[],"power":[],"origin":"apple","healthKitUUID":"abc"}
"""
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
do {
    let legacyRecord = try decoder.decode(WorkoutRecord.self, from: Data(legacy.utf8))
    check(legacyRecord.verticalOscillation.isEmpty, "missing verticalOscillation decodes as []")
    check(legacyRecord.heartRate.count == 2, "legacy heart series still decodes")
    check(legacyRecord.healthKitUUID == "abc", "legacy health id decodes")
    check(legacyRecord.trainingDurationSeconds == 0, "missing training duration is unknown")
    check(legacyRecord.elapsedDuration == 600, "legacy elapsed is end minus start")
    check(legacyRecord.trainingDuration == 600, "unknown training duration falls back to elapsed")
    check(legacyRecord.conditions == nil && legacyRecord.startPlace == nil, "missing context stays empty")
    check(legacyRecord.distanceProgress.isEmpty, "missing distance progress decodes as empty")
    check(legacyRecord.pauseIntervals.isEmpty, "missing pauses decode as empty")
    check(legacyRecord.lapMarks.isEmpty, "missing lap marks decode as empty")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    var enriched = legacyRecord
    enriched.trainingDurationSeconds = 480
    enriched.conditions = WorkoutConditions(
        temperatureCelsius: 18.7,
        relativeHumidityPercent: 71,
        airQualityIndex: 84,
        airQualityGrade: "良",
        weatherReady: true,
        airReady: true
    )
    enriched.startPlace = WorkoutStartPlace(name: "上海长风公园")
    enriched.distanceProgress = [SeriesPoint(second: 0, value: 0), SeriesPoint(second: 12, value: 40)]
    enriched.pauseIntervals = [WorkoutPause(startSecond: 4, endSecond: 9)]
    enriched.lapMarks = [WorkoutLapMark(second: 30, distanceMeters: 1_000)]
    let enrichedData = try encoder.encode(enriched)
    let decodedEnriched = try decoder.decode(WorkoutRecord.self, from: enrichedData)
    check(decodedEnriched.trainingDurationSeconds == 480, "training duration round-trips")
    check(decodedEnriched.trainingDuration == 480, "stored training duration within elapsed is used")
    check(decodedEnriched.conditions?.temperatureCelsius == 18.7, "temperature round-trips")
    check(decodedEnriched.conditions?.airQualityGrade == "良", "air grade round-trips")
    check(decodedEnriched.conditions?.weatherReady == true && decodedEnriched.conditions?.airReady == true, "ready flags round-trip")
    check(decodedEnriched.startPlace?.name == "上海长风公园", "place name round-trips")
    check(decodedEnriched.distanceProgress.count == 2 && decodedEnriched.distanceProgress[1].value == 40, "distance progress round-trips")
    check(decodedEnriched.pauseIntervals.count == 1 && decodedEnriched.pauseIntervals[0].startSecond == 4, "pause intervals round-trip")
    check(decodedEnriched.lapMarks.count == 1 && decodedEnriched.lapMarks[0].second == 30, "lap marks round-trip")
    enriched.trainingDurationSeconds = 10_000
    check(enriched.trainingDuration == 600, "a stored duration past elapsed falls back")

    let legacyDatabase = try decoder.decode(Database.self, from: Data("{\"workouts\":[\(legacy)]}".utf8))
    check(legacyDatabase.workouts.count == 1, "phone file without the new key still loads")
    check(legacyDatabase.workouts[0].verticalOscillation.isEmpty, "loaded workout defaults the new series")

    let encoded = try encoder.encode(imported)
    var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    check(object["verticalOscillation"] != nil, "encoder writes verticalOscillation")
    object.removeValue(forKey: "verticalOscillation")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try decoder.decode(WorkoutRecord.self, from: stripped)
    check(decoded.verticalOscillation.isEmpty, "stripped key defaults to []")
    check(decoded.power == imported.power, "other series survive a missing key")
    object.removeValue(forKey: "distanceProgress")
    object.removeValue(forKey: "pauseIntervals")
    object.removeValue(forKey: "lapMarks")
    let strippedCurve = try JSONSerialization.data(withJSONObject: object)
    let decodedCurve = try decoder.decode(WorkoutRecord.self, from: strippedCurve)
    check(decodedCurve.distanceProgress.isEmpty && decodedCurve.pauseIntervals.isEmpty, "missing curve keys decode as empty")
    check(decodedCurve.lapMarks.isEmpty, "missing lap marks decode as empty after a strip")
    check(decodedCurve.power == imported.power, "stripping the curve keeps the other series")
    let roundTrip = try decoder.decode(WorkoutRecord.self, from: encoded)
    check(roundTrip.verticalOscillation == oscillation, "present vertical oscillation round-trips")
} catch {
    check(false, "legacy workout failed to decode: \(error)")
}

let steps = 1_500.0
let elapsedSpan = 900.0
let movingSpan = 600.0
near(
    CadenceMath.stepsPerMinute(steps: steps, duration: elapsedSpan),
    100,
    tolerance: 0.01,
    "steps over elapsed minutes"
)
near(
    CadenceMath.stepsPerMinute(
        steps: steps,
        duration: CadenceMath.trainingDuration(moving: movingSpan, elapsed: elapsedSpan)
    ),
    150,
    tolerance: 0.01,
    "steps over training minutes"
)
check(CadenceMath.trainingDuration(moving: movingSpan, elapsed: elapsedSpan) == movingSpan, "moving time is the cadence divisor")
check(CadenceMath.trainingDuration(moving: 0, elapsed: elapsedSpan) == elapsedSpan, "missing moving time falls back to elapsed")

var stale = makeWorkout(averageCadence: 100)
stale.distanceMeters = 1000
stale.trainingDurationSeconds = movingSpan
stale.averageHeartRate = 120
stale.heartRate = [
    SeriesPoint(second: 0, value: 150),
    SeriesPoint(second: 10, value: 150),
    SeriesPoint(second: 20, value: 150),
    SeriesPoint(second: 200, value: 150),
    SeriesPoint(second: 210, value: 150)
]
stale.cadenceSeries = [
    SeriesPoint(second: 0, value: 180),
    SeriesPoint(second: 10, value: 180),
    SeriesPoint(second: 20, value: 180),
    SeriesPoint(second: 200, value: 160),
    SeriesPoint(second: 210, value: 160)
]
stale.stride = [
    SeriesPoint(second: 0, value: 0.86),
    SeriesPoint(second: 210, value: 0.86)
]
near(stale.resolvedAverageCadence, 100, tolerance: 0.01, "headline cadence is the stored step total")
check(abs(stale.resolvedAverageCadence - (5200.0 / 30.0)) > 1, "series mean is not the headline cadence")
near(stale.resolvedAverageHeartRate, 150, tolerance: 0.01, "heart rate uses the training-interval series")
check(abs(stale.resolvedAverageHeartRate - 120) > 1, "stale stored heart rate is not what the detail shows")
near(stale.averageStrideMeters, 1, tolerance: 0.001, "stride is distance divided by total steps")
check(abs(stale.averageStrideMeters - 0.86) > 0.05, "running-stride series is not the headline stride")
near(
    stale.averageStrideMeters * (stale.resolvedAverageCadence / 60),
    1000 / stale.averagePaceSecPerKm,
    tolerance: 0.001,
    "stride × cadence/60 matches 1000/pace"
)

var bare = makeWorkout(averageCadence: 158)
bare.averageHeartRate = 142
bare.heartRate = []
bare.cadenceSeries = []
check(bare.resolvedAverageCadence == 158, "empty cadence series keeps the stored average")
check(bare.resolvedAverageHeartRate == 142, "empty heart series keeps the stored average")

var zeros = makeWorkout(
    averageCadence: 158,
    cadenceSeries: [SeriesPoint(second: 1, value: 0), SeriesPoint(second: 5, value: -3)]
)
check(zeros.resolvedAverageCadence == 158, "non-positive cadence samples are not a series average")

var sparse = makeWorkout(
    averageCadence: 100,
    cadenceSeries: [SeriesPoint(second: 0, value: 170), SeriesPoint(second: 120, value: 190)]
)
near(sparse.resolvedAverageCadence, 100, tolerance: 0.01, "a stored step total wins over pause-separated samples")

var oneSample = makeWorkout(averageCadence: 100, cadenceSeries: [SeriesPoint(second: 4, value: 172)])
near(oneSample.resolvedAverageCadence, 100, tolerance: 0.01, "one cadence sample does not replace the step total")

var coveredHalf = makeWorkout(averageCadence: 160)
coveredHalf.distanceMeters = 1000
coveredHalf.trainingDurationSeconds = 600
var halfSeries: [SeriesPoint] = []
for second in stride(from: 0, through: 300, by: 10) {
    halfSeries.append(SeriesPoint(second: Double(second), value: 160))
}
coveredHalf.cadenceSeries = halfSeries
near(coveredHalf.resolvedAverageCadence, 80, tolerance: 0.5, "gaps inside training time are not dropped from the step total")
near(
    coveredHalf.averageStrideMeters * (coveredHalf.resolvedAverageCadence / 60),
    1000 / coveredHalf.averagePaceSecPerKm,
    tolerance: 0.02,
    "rebuilt cadence still matches pace"
)

var elapsedOnly = makeWorkout(averageCadence: 100)
var retrained = makeWorkout(averageCadence: 150)
let replacedCadence = WorkoutImport.merging(elapsedOnly, with: retrained)
check(replacedCadence.averageCadence == 150, "re-import replaces elapsed cadence when no series can correct it")

let corrected = RecordStats.make(workouts: [stale], window: .all, now: stale.start)
near(corrected.averageCadence, stale.resolvedAverageCadence, tolerance: 0.01, "stats cadence uses the training-interval series")
near(corrected.averageHeartRate, stale.resolvedAverageHeartRate, tolerance: 0.01, "stats heart rate uses the training-interval series")
near(corrected.averageStrideMeters, stale.averageStrideMeters, tolerance: 0.001, "stats stride follows the corrected cadence")
check(
    corrected.totalSessionLoad == Double(stale.sessionLoad),
    "stats load uses the training-interval heart rate"
)

do {
    let legacy = Data(#"{"index":1,"paceSecPerKm":300,"cadence":170,"heartRate":150,"partial":false}"#.utf8)
    let decoded = try JSONDecoder().decode(KilometerSplit.self, from: legacy)
    check(decoded.energyKilocalories == 0, "old splits decode without per-km energy")
    check(decoded.distanceMeters == 0 && decoded.durationSeconds == 0, "old splits decode without distance or duration")
    check(decoded.index == 1 && decoded.paceSecPerKm == 300 && decoded.partial == false, "old split fields stay")
    check(decoded.listedDistanceText == "1.00", "a legacy full kilometer still lists 1.00")
    check(decoded.listedTimeText == "05:00", "a legacy full kilometer lists its pace as the time")
    let stamped = KilometerSplit(
        index: 2,
        paceSecPerKm: 310,
        cadence: 168,
        heartRate: 148,
        partial: true,
        energyKilocalories: 42,
        distanceMeters: 550,
        durationSeconds: 170.5
    )
    let round = try JSONDecoder().decode(KilometerSplit.self, from: JSONEncoder().encode(stamped))
    near(round.energyKilocalories, 42, tolerance: 0.01, "split energy round-trips")
    near(round.distanceMeters, 550, tolerance: 0.01, "split distance round-trips")
    near(round.durationSeconds, 170.5, tolerance: 0.01, "split duration round-trips")
    check(round.partial && round.heartRate == 148 && round.cadence == 168, "split distance coding keeps the other fields")
    check(round.listedDistanceText == "0.55", "leftover distance is the real kilometers")
    check(round.listedTimeText == "02:50", "leftover time is the real duration")
    check(round.listedDistanceText != "未满" && round.listedTimeText != "—", "leftover row has no dash and no 未满")
} catch {
    check(false, "split energy coding failed: \(error)")
}

func lineRoute(points: Int, pauseAt: Int, pauseSeconds: Double) -> [GeoPoint] {
    var rows: [GeoPoint] = []
    var elapsed = 0.0
    for index in 0..<points {
        if index == pauseAt {
            elapsed += pauseSeconds
        }
        rows.append(GeoPoint(
            latitude: 31.24 + (Double(index) * 100) / 111_320,
            longitude: 121.49,
            altitude: 20,
            timestamp: start.addingTimeInterval(elapsed)
        ))
        elapsed += 30
    }
    return rows
}

let officialEnd = start.addingTimeInterval(3_000)
let official = HealthSeries.track(
    route: lineRoute(points: 26, pauseAt: 10, pauseSeconds: 1_200),
    distanceSamples: [],
    workoutStart: start,
    workoutEnd: officialEnd,
    referenceDistanceMeters: 3_550,
    heartRate: [],
    cadence: [],
    trainingDuration: 800
)
check(official.splits.filter { !$0.partial }.count == 3, "official 3.55 km is three full kilometers, got \(official.splits.count)")
check(official.splits.count == 4, "3.55 km keeps a leftover row, got \(official.splits.count)")
check(official.splits.dropLast().allSatisfy { abs($0.distanceMeters - 1000) < 1 && !$0.partial }, "full rows are 1 km")
near(official.splits.last?.distanceMeters ?? 0, 550, tolerance: 1, "leftover is 0.55 km")
check(official.splits.last?.partial == true, "leftover row is partial")
check((official.splits.last?.durationSeconds ?? 0) > 0, "leftover duration is stored")
check(official.splits.last?.listedDistanceText == "0.55", "leftover lists 0.55, got \(official.splits.last?.listedDistanceText ?? "")")
check(official.splits.last?.listedTimeText != "—" && official.splits.last?.listedDistanceText != "未满", "leftover hides neither time nor distance")
let officialSum = official.splits.reduce(0.0) { $0 + $1.durationSeconds }
near(officialSum, 800, tolerance: 0.5, "split times sum to the training total")
check(official.splits.allSatisfy { $0.durationSeconds < 500 }, "a 20 minute pause is not dumped into one kilometer")
check(official.splits.dropLast().allSatisfy { $0.listedDistanceText == "1.00" }, "full kilometers stay 1.00")

let unscaled = HealthSeries.track(
    route: lineRoute(points: 26, pauseAt: -1, pauseSeconds: 0),
    distanceSamples: [],
    workoutStart: start,
    workoutEnd: officialEnd,
    referenceDistanceMeters: 20_000,
    heartRate: [],
    cadence: [],
    trainingDuration: 0
)
check(unscaled.splits.filter { !$0.partial }.count == 2, "a distance far from the route is not scaled, got \(unscaled.splits.count)")

var staleRows = makeWorkout()
staleRows.distanceMeters = 3_550
staleRows.trainingDurationSeconds = 800
staleRows.end = officialEnd
staleRows.route = lineRoute(points: 26, pauseAt: 10, pauseSeconds: 1_200)
staleRows.splits = [
    KilometerSplit(index: 1, paceSecPerKm: 900, cadence: 120, heartRate: 140, partial: false),
    KilometerSplit(index: 2, paceSecPerKm: 2_200, cadence: 120, heartRate: 150, partial: false),
    KilometerSplit(index: 3, paceSecPerKm: 355, cadence: 172, heartRate: 174, partial: true)
]
let rebuilt = staleRows.resolvedSplits
check(rebuilt.count == 4, "stored GPS splits are rebuilt from the official distance, got \(rebuilt.count)")
near(rebuilt.last?.distanceMeters ?? 0, 550, tolerance: 1, "rebuilt leftover distance")
near(rebuilt.reduce(0.0) { $0 + $1.durationSeconds }, 800, tolerance: 0.5, "rebuilt splits sum to training time")
check(rebuilt.last?.listedDistanceText == "0.55" && rebuilt.last?.listedTimeText != "—", "rebuilt leftover is shown with real numbers")
check(staleRows.splits.count == 3, "rebuild does not rewrite the stored array")
check(official.distanceProgress.isEmpty, "a route-only rebuild does not invent official distance progress")

let paired = WorkoutPause.intervals(
    from: [
        WorkoutPause.Mark(second: 100, isResume: false, duration: 0),
        WorkoutPause.Mark(second: 400, isResume: true, duration: 0)
    ],
    elapsed: 1_000
)
check(paired.count == 1 && paired[0].startSecond == 100 && paired[0].endSecond == 400, "pause and resume pair into one interval")
let closedPause = WorkoutPause.intervals(
    from: [WorkoutPause.Mark(second: 100, isResume: false, duration: 50)],
    elapsed: 1_000
)
check(closedPause.count == 1 && closedPause[0].endSecond == 150, "a pause event with duration is already closed")
let unclosed = WorkoutPause.intervals(
    from: [WorkoutPause.Mark(second: 800, isResume: false, duration: 0)],
    elapsed: 1_000
)
check(unclosed.count == 1 && unclosed[0].endSecond == 1_000, "an open pause runs to the workout end")
let nested = WorkoutPause.intervals(
    from: [
        WorkoutPause.Mark(second: 0, isResume: false, duration: 0),
        WorkoutPause.Mark(second: 10, isResume: false, duration: 0),
        WorkoutPause.Mark(second: 20, isResume: true, duration: 0),
        WorkoutPause.Mark(second: 40, isResume: true, duration: 0)
    ],
    elapsed: 1_000
)
check(nested.count == 1 && nested[0].startSecond == 0 && nested[0].endSecond == 40, "nested pause and auto-pause stay one interval")
let overlapped = WorkoutPause.merged([
    WorkoutPause(startSecond: 100, endSecond: 400),
    WorkoutPause(startSecond: 200, endSecond: 500)
])
check(overlapped.count == 1 && overlapped[0].endSecond == 500, "overlapping pauses merge")

let cumulativeCuts = HealthSeries.track(
    route: northRoute(count: 26, stepMeters: 100, stepSeconds: 30, firstOffset: 0, altitude: 20),
    distanceSamples: [
        sample(0, 600, 1_000),
        sample(600, 1_500, 2_000),
        sample(1_500, 1_800, 2_500)
    ],
    workoutStart: start,
    workoutEnd: start.addingTimeInterval(1_800),
    referenceDistanceMeters: 2_500,
    heartRate: [
        SeriesPoint(second: 100, value: 140),
        SeriesPoint(second: 800, value: 160),
        SeriesPoint(second: 1_600, value: 151)
    ],
    cadence: [
        SeriesPoint(second: 100, value: 170),
        SeriesPoint(second: 800, value: 150),
        SeriesPoint(second: 1_600, value: 148)
    ],
    trainingDuration: 1_800
)
check(cumulativeCuts.splits.count == 3, "official 2.5 km is two full rows and a leftover, got \(cumulativeCuts.splits.count)")
near(cumulativeCuts.splits[0].durationSeconds, 600, tolerance: 0.5, "km 1 follows the cumulative distance clock")
near(cumulativeCuts.splits[1].durationSeconds, 900, tolerance: 0.5, "km 2 follows the cumulative distance clock")
near(cumulativeCuts.splits[2].durationSeconds, 300, tolerance: 0.5, "leftover time follows the cumulative distance clock")
near(cumulativeCuts.splits[2].distanceMeters, 500, tolerance: 1, "leftover distance is the real remainder")
check(cumulativeCuts.splits[2].partial, "leftover row is partial")
check(cumulativeCuts.splits[2].listedDistanceText == "0.50", "leftover lists 0.50, got \(cumulativeCuts.splits[2].listedDistanceText)")
check(cumulativeCuts.splits[2].listedTimeText == "05:00", "leftover lists its own time, got \(cumulativeCuts.splits[2].listedTimeText)")
check(cumulativeCuts.splits[2].listedDistanceText != "未满" && cumulativeCuts.splits[2].listedTimeText != "—", "leftover hides neither field")
check(cumulativeCuts.splits.dropLast().allSatisfy { $0.listedDistanceText == "1.00" && !$0.partial }, "full official kilometers stay 1.00")
near(cumulativeCuts.splits[0].heartRate, 140, tolerance: 0.01, "km 1 heart uses the official window")
near(cumulativeCuts.splits[1].heartRate, 160, tolerance: 0.01, "km 2 heart uses the official window")
near(cumulativeCuts.splits[2].heartRate, 151, tolerance: 0.01, "leftover heart uses the official window")
near(cumulativeCuts.splits[0].cadence, 170, tolerance: 0.01, "km 1 cadence uses the official window")
near(cumulativeCuts.splits[1].cadence, 150, tolerance: 0.01, "km 2 cadence uses the official window")
near(cumulativeCuts.pace[0].value, 300, tolerance: 2, "pace chart still follows the route")
check(!cumulativeCuts.distanceProgress.isEmpty, "official distance progress is kept")
near(cumulativeCuts.splits.reduce(0) { $0 + $1.durationSeconds }, 1_800, tolerance: 0.5, "official split times sum to training time")

let gapped = HealthSeries.track(
    route: [],
    distanceSamples: [
        sample(0, 400, 1_000),
        sample(700, 1_000, 1_000)
    ],
    workoutStart: start,
    workoutEnd: start.addingTimeInterval(1_000),
    referenceDistanceMeters: 2_000,
    heartRate: [],
    cadence: [],
    trainingDuration: 700
)
check(gapped.splits.count == 2, "a gap between distance samples is still two kilometers, got \(gapped.splits.count)")
near(gapped.splits[0].durationSeconds, 400, tolerance: 0.5, "a kilometer that already closed keeps the time up to the mark")
near(gapped.splits[1].durationSeconds, 600, tolerance: 0.5, "the gap after the mark stays on the kilometer already in progress")
near(gapped.splits.reduce(0) { $0 + $1.durationSeconds }, 1_000, tolerance: 0.5, "a sample gap is not scaled back down to training duration")

let openGap = HealthSeries.track(
    route: [],
    distanceSamples: [
        sample(0, 200, 400),
        sample(500, 800, 600),
        sample(800, 1_100, 1_000)
    ],
    workoutStart: start,
    workoutEnd: start.addingTimeInterval(1_100),
    referenceDistanceMeters: 2_000,
    heartRate: [],
    cadence: [],
    trainingDuration: 400
)
check(openGap.splits.count == 2, "a mid-kilometer gap is still two rows, got \(openGap.splits.count)")
near(openGap.splits[0].durationSeconds, 800, tolerance: 0.5, "gap time lands in the kilometer that had already started")
near(openGap.splits[1].durationSeconds, 300, tolerance: 0.5, "a gap is not dumped into the following kilometer")
near(openGap.splits.reduce(0) { $0 + $1.durationSeconds }, 1_100, tolerance: 0.5, "mid-kilometer gap splits are not scaled to training duration")

let pausedGap = HealthSeries.track(
    route: [],
    distanceSamples: [
        sample(0, 200, 400),
        sample(500, 800, 600),
        sample(800, 1_100, 1_000)
    ],
    workoutStart: start,
    workoutEnd: start.addingTimeInterval(1_100),
    referenceDistanceMeters: 2_000,
    heartRate: [],
    cadence: [],
    trainingDuration: 400,
    pauses: [WorkoutPause(startSecond: 350, endSecond: 450)]
)
near(pausedGap.splits[0].durationSeconds, 700, tolerance: 0.5, "a pause inside a sample gap is left out of that kilometer")
near(pausedGap.splits[1].durationSeconds, 300, tolerance: 0.5, "a pause inside a gap does not change the next kilometer")
near(pausedGap.splits.reduce(0) { $0 + $1.durationSeconds }, 1_000, tolerance: 0.5, "paused gap time is not put back by scaling")

let unscaledCurve = HealthSeries.track(
    route: [],
    distanceSamples: [
        sample(0, 500, 1_000),
        sample(500, 1_000, 1_000)
    ],
    workoutStart: start,
    workoutEnd: start.addingTimeInterval(1_000),
    referenceDistanceMeters: 2_200,
    heartRate: [],
    cadence: [],
    trainingDuration: 1_600
)
check(unscaledCurve.splits.count == 2, "an official curve within 15% is not stretched into an extra partial, got \(unscaledCurve.splits.count)")
near(unscaledCurve.splits[0].durationSeconds, 500, tolerance: 0.5, "official distance is not scaled, so the first mark stays at the sample")
near(unscaledCurve.splits[1].durationSeconds, 500, tolerance: 0.5, "official split durations are not scaled to training time")
check(unscaledCurve.splits.allSatisfy { abs($0.distanceMeters - 1_000) < 1 && !$0.partial }, "official rows keep the sample kilometers")

let spanned = HealthSeries.track(
    route: [],
    distanceSamples: [
        sample(0, 400, 1_000),
        sample(400, 1_000, 1_000)
    ],
    workoutStart: start,
    workoutEnd: start.addingTimeInterval(1_000),
    referenceDistanceMeters: 2_000,
    heartRate: [
        SeriesPoint(second: 100, value: 142),
        SeriesPoint(second: 500, value: 90),
        SeriesPoint(second: 800, value: 158)
    ],
    cadence: [
        SeriesPoint(second: 100, value: 168),
        SeriesPoint(second: 500, value: 40),
        SeriesPoint(second: 800, value: 152)
    ],
    trainingDuration: 700,
    pauses: [WorkoutPause(startSecond: 400, endSecond: 700)]
)
near(spanned.splits[0].durationSeconds, 400, tolerance: 0.5, "a pause does not scale the earlier kilometer")
near(spanned.splits[1].durationSeconds, 300, tolerance: 0.5, "a pause inside a distance sample is left out of that kilometer")
near(spanned.splits[0].heartRate, 142, tolerance: 0.01, "heart before the pause stays")
near(spanned.splits[1].heartRate, 158, tolerance: 0.01, "heart during the pause is left out")
near(spanned.splits[1].cadence, 152, tolerance: 0.01, "cadence during the pause is left out")
near(spanned.splits.reduce(0) { $0 + $1.durationSeconds }, 700, tolerance: 0.5, "paused splits still sum to training time")
check(spanned.pauseIntervals.count == 1, "the track keeps the pause interval")

func driftRoute() -> (points: [GeoPoint], pause: WorkoutPause, finish: Date, meters: Double) {
    var rows: [GeoPoint] = []
    var elapsed = 0.0
    var north = 0.0
    func add() {
        rows.append(GeoPoint(
            latitude: 31.24 + north / 111_320,
            longitude: 121.49,
            altitude: 20,
            timestamp: start.addingTimeInterval(elapsed)
        ))
    }
    add()
    for _ in 0..<20 {
        elapsed += 15
        north += 50
        add()
    }
    let pauseStart = elapsed
    for _ in 0..<30 {
        elapsed += 10
        north += 2
        add()
    }
    let pause = WorkoutPause(startSecond: pauseStart, endSecond: elapsed)
    for _ in 0..<20 {
        elapsed += 15
        north += 50
        add()
    }
    return (rows, pause, start.addingTimeInterval(elapsed), north)
}

let drifted = driftRoute()
let gpsPaused = HealthSeries.track(
    route: drifted.points,
    distanceSamples: [],
    workoutStart: start,
    workoutEnd: drifted.finish,
    referenceDistanceMeters: drifted.meters,
    heartRate: [],
    cadence: [],
    trainingDuration: 600,
    pauses: [drifted.pause]
)
check(gpsPaused.distanceProgress.isEmpty, "missing distance samples do not store an official curve")
check(gpsPaused.splits.count == 3, "gps fallback still cuts the route, got \(gpsPaused.splits.count)")
near(gpsPaused.splits[0].durationSeconds, 300, tolerance: 5, "gps fallback keeps the first kilometer when a later pause is removed")
check(gpsPaused.splits.allSatisfy { $0.durationSeconds < 400 }, "a recorded pause is not dumped into a gps kilometer")
near(gpsPaused.splits.reduce(0) { $0 + $1.durationSeconds }, 600, tolerance: 0.5, "gps fallback splits still sum to training time")
check(gpsPaused.splits.last?.partial == true, "gps fallback keeps a real leftover")
check((gpsPaused.splits.last?.distanceMeters ?? 0) > 30, "gps fallback leftover keeps its distance")
check(gpsPaused.splits.last?.listedDistanceText != "未满" && gpsPaused.splits.last?.listedTimeText != "—", "gps fallback leftover is not a dash or 未满")

var storedCuts = makeWorkout()
storedCuts.distanceMeters = 2_000
storedCuts.trainingDurationSeconds = 700
storedCuts.end = start.addingTimeInterval(1_000)
storedCuts.splits = [
    KilometerSplit(index: 1, paceSecPerKm: 200, cadence: 160, heartRate: 140, partial: false, distanceMeters: 1_000, durationSeconds: 200),
    KilometerSplit(index: 2, paceSecPerKm: 800, cadence: 160, heartRate: 150, partial: false, distanceMeters: 1_000, durationSeconds: 800)
]
storedCuts.distanceProgress = [
    SeriesPoint(second: 0, value: 0),
    SeriesPoint(second: 600, value: 1_000),
    SeriesPoint(second: 1_000, value: 2_000)
]
storedCuts.pauseIntervals = [WorkoutPause(startSecond: 600, endSecond: 900)]
storedCuts.heartRate = [
    SeriesPoint(second: 100, value: 141),
    SeriesPoint(second: 700, value: 99),
    SeriesPoint(second: 950, value: 156)
]
let rebuiltCuts = storedCuts.resolvedSplits
near(rebuiltCuts[0].durationSeconds, 600, tolerance: 0.5, "display cuts the stored official curve instead of the old gps rows")
near(rebuiltCuts[1].durationSeconds, 100, tolerance: 0.5, "display leaves the stored pause out of the second kilometer")
near(rebuiltCuts[0].heartRate, 141, tolerance: 0.01, "display heart follows the official window")
near(rebuiltCuts[1].heartRate, 156, tolerance: 0.01, "display heart skips the stored pause")
check(storedCuts.splits[0].durationSeconds == 200, "display rebuild does not rewrite the stored rows")
check(rebuiltCuts.allSatisfy { !$0.partial } && rebuiltCuts.dropLast().allSatisfy { $0.listedDistanceText == "1.00" }, "rebuilt full rows stay 1.00")

var untrusted = storedCuts
untrusted.distanceProgress = [SeriesPoint(second: 0, value: 0), SeriesPoint(second: 100, value: 800)]
untrusted.pauseIntervals = []
untrusted.trainingDurationSeconds = 1_000
untrusted.splits = [
    KilometerSplit(index: 1, paceSecPerKm: 200, cadence: 160, heartRate: 140, partial: false, distanceMeters: 1_000, durationSeconds: 200),
    KilometerSplit(index: 2, paceSecPerKm: 800, cadence: 160, heartRate: 150, partial: false, distanceMeters: 1_000, durationSeconds: 800)
]
check(untrusted.resolvedSplits[0].durationSeconds == 200, "a distance curve far from the official total does not replace matching rows")
check(untrusted.resolvedSplits.count == 2, "untrusted progress keeps the stored rows, got \(untrusted.resolvedSplits.count)")

var storedGap = makeWorkout()
storedGap.distanceMeters = 2_000
storedGap.end = start.addingTimeInterval(1_000)
storedGap.trainingDurationSeconds = 900
storedGap.splits = [
    KilometerSplit(index: 1, paceSecPerKm: 200, cadence: 160, heartRate: 140, partial: false, distanceMeters: 1_000, durationSeconds: 200),
    KilometerSplit(index: 2, paceSecPerKm: 700, cadence: 160, heartRate: 150, partial: false, distanceMeters: 1_000, durationSeconds: 700)
]
storedGap.distanceProgress = [
    SeriesPoint(second: 0, value: 0),
    SeriesPoint(second: 400, value: 1_000),
    SeriesPoint(second: 700, value: 1_000),
    SeriesPoint(second: 1_000, value: 2_000)
]
let rebuiltGap = storedGap.resolvedSplits
near(rebuiltGap[0].durationSeconds, 400, tolerance: 0.5, "a stored curve keeps the closed kilometer")
near(rebuiltGap[1].durationSeconds, 600, tolerance: 0.5, "a stored curve adds the gap to the kilometer already in progress")
near(rebuiltGap.reduce(0) { $0 + $1.durationSeconds }, 1_000, tolerance: 0.5, "a stored official curve is not scaled to training duration")
check(storedGap.splits[0].durationSeconds == 200 && storedGap.splits[1].durationSeconds == 700, "gap rebuild does not rewrite the stored rows")

let lappedEnd = start.addingTimeInterval(1_500)
let lappedHearts = [
    SeriesPoint(second: 100, value: 140),
    SeriesPoint(second: 570, value: 180),
    SeriesPoint(second: 900, value: 155)
]
let lappedSamples = [
    sample(0, 600, 1_000),
    sample(600, 1_200, 1_000),
    sample(1_200, 1_500, 400)
]
let lapped = HealthSeries.track(
    route: [],
    distanceSamples: lappedSamples,
    workoutStart: start,
    workoutEnd: lappedEnd,
    referenceDistanceMeters: 2_400,
    heartRate: lappedHearts,
    cadence: [],
    trainingDuration: 2_000,
    pauses: [WorkoutPause(startSecond: 700, endSecond: 800)],
    laps: [
        WorkoutLapMark(second: 540, distanceMeters: 1_000),
        WorkoutLapMark(second: 1_100, distanceMeters: 1_000)
    ]
)
check(lapped.splits.count == 3, "equal kilometer laps keep a leftover row, got \(lapped.splits.count)")
near(lapped.splits[0].durationSeconds, 540, tolerance: 0.5, "the first lap timestamp replaces the distance-curve cut")
near(lapped.splits[1].durationSeconds, 460, tolerance: 0.5, "a pause between lap marks is left out of that kilometer")
near(lapped.splits[2].distanceMeters, 400, tolerance: 1, "the lap leftover is the real remainder")
near(lapped.splits[2].durationSeconds, 400, tolerance: 0.5, "the lap leftover keeps its own time")
near(lapped.splits[0].heartRate, 140, tolerance: 0.01, "heart follows the lap window, not the later curve cut")
near(lapped.splits[1].heartRate, 167.5, tolerance: 0.01, "heart after the lap mark stays in the next kilometer")
near(lapped.splits.reduce(0) { $0 + $1.durationSeconds }, 1_400, tolerance: 0.5, "lap splits are not scaled to training duration")
check(lapped.splits[2].partial && lapped.splits[2].listedDistanceText == "0.40", "lap leftover lists 0.40, got \(lapped.splits[2].listedDistanceText)")
check(lapped.splits[2].listedTimeText != "—" && lapped.splits[2].listedDistanceText != "未满", "lap leftover hides neither field")

let unevenLaps = HealthSeries.track(
    route: [],
    distanceSamples: lappedSamples,
    workoutStart: start,
    workoutEnd: lappedEnd,
    referenceDistanceMeters: 2_400,
    heartRate: [],
    cadence: [],
    trainingDuration: 2_000,
    pauses: [WorkoutPause(startSecond: 700, endSecond: 800)],
    laps: [
        WorkoutLapMark(second: 540, distanceMeters: 1_000),
        WorkoutLapMark(second: 1_100, distanceMeters: 400)
    ]
)
near(unevenLaps.splits[0].durationSeconds, 600, tolerance: 0.5, "unequal laps leave the official distance curve in charge")
near(unevenLaps.splits[1].durationSeconds, 500, tolerance: 0.5, "the curve still removes a pause inside the second kilometer")

let crowdedLaps = HealthSeries.track(
    route: [],
    distanceSamples: [
        sample(0, 500, 1_000),
        sample(500, 1_000, 1_000)
    ],
    workoutStart: start,
    workoutEnd: start.addingTimeInterval(1_000),
    referenceDistanceMeters: 2_000,
    heartRate: [],
    cadence: [],
    trainingDuration: 1_600,
    laps: (0..<10).map { WorkoutLapMark(second: Double($0 + 1) * 40, distanceMeters: 0) }
)
near(crowdedLaps.splits[0].durationSeconds, 500, tolerance: 0.5, "laps that are not one per kilometer do not replace the curve")
check(crowdedLaps.splits.count == 2, "extra short laps do not add rows, got \(crowdedLaps.splits.count)")

let unmarkedLaps = HealthSeries.track(
    route: route,
    distanceSamples: [],
    workoutStart: start,
    workoutEnd: start.addingTimeInterval(1_200),
    referenceDistanceMeters: 2_500,
    heartRate: [],
    cadence: [],
    trainingDuration: 2_000,
    laps: [
        WorkoutLapMark(second: 400, distanceMeters: 0),
        WorkoutLapMark(second: 900, distanceMeters: 0)
    ]
)
near(unmarkedLaps.splits[0].durationSeconds, 400, tolerance: 0.5, "laps without a length still cut when they match the kilometer count")
near(unmarkedLaps.splits[1].durationSeconds, 500, tolerance: 0.5, "the second unmarked lap is the next boundary")
near(unmarkedLaps.splits[2].distanceMeters, 500, tolerance: 1, "unmarked laps keep the real leftover distance")
near(unmarkedLaps.splits[2].durationSeconds, 300, tolerance: 0.5, "unmarked laps keep the real leftover time")
near(unmarkedLaps.splits.reduce(0) { $0 + $1.durationSeconds }, 1_200, tolerance: 0.5, "unmarked lap splits are not scaled to training time")
near(unmarkedLaps.pace[0].value, 300, tolerance: 2, "pace chart still follows the route when laps cut the kilometers")
check(unmarkedLaps.distanceProgress.isEmpty, "laps do not invent an official distance curve")

var storedLaps = makeWorkout()
storedLaps.distanceMeters = 2_400
storedLaps.end = lappedEnd
storedLaps.trainingDurationSeconds = 2_000
storedLaps.heartRate = lappedHearts
storedLaps.pauseIntervals = [WorkoutPause(startSecond: 700, endSecond: 800)]
storedLaps.distanceProgress = [
    SeriesPoint(second: 0, value: 0),
    SeriesPoint(second: 600, value: 1_000),
    SeriesPoint(second: 1_200, value: 2_000),
    SeriesPoint(second: 1_500, value: 2_400)
]
storedLaps.splits = [
    KilometerSplit(index: 1, paceSecPerKm: 600, cadence: 160, heartRate: 140, partial: false, distanceMeters: 1_000, durationSeconds: 600),
    KilometerSplit(index: 2, paceSecPerKm: 500, cadence: 160, heartRate: 150, partial: false, distanceMeters: 1_000, durationSeconds: 500),
    KilometerSplit(index: 3, paceSecPerKm: 750, cadence: 160, heartRate: 155, partial: true, distanceMeters: 400, durationSeconds: 300)
]
let beforeLaps = storedLaps.resolvedSplits
near(beforeLaps[0].durationSeconds, 600, tolerance: 0.5, "without lap marks the stored curve still cuts the kilometers")
var importedLaps = storedLaps
importedLaps.lapMarks = [
    WorkoutLapMark(second: 540, distanceMeters: 1_000),
    WorkoutLapMark(second: 1_100, distanceMeters: 1_000)
]
let mergedLaps = WorkoutImport.merging(storedLaps, with: importedLaps)
check(mergedLaps.lapMarks.count == 2 && mergedLaps.lapMarks[1].second == 1_100, "merge stores lap marks")
let keptLaps = WorkoutImport.merging(mergedLaps, with: makeWorkout())
check(keptLaps.lapMarks.count == 2, "blank import does not clear lap marks")
var replacementLaps = importedLaps
replacementLaps.lapMarks = [WorkoutLapMark(second: 10, distanceMeters: 1_000)]
let alreadyLapped = WorkoutImport.merging(mergedLaps, with: replacementLaps)
check(alreadyLapped.lapMarks.count == 2 && alreadyLapped.lapMarks[0].second == 540, "merge keeps lap marks already stored")
let shownLaps = mergedLaps.resolvedSplits
near(shownLaps[0].durationSeconds, 540, tolerance: 0.5, "display prefers stored lap marks over the distance curve")
near(shownLaps[1].durationSeconds, 460, tolerance: 0.5, "display leaves the stored pause out of the lap kilometer")
near(shownLaps[0].heartRate, 140, tolerance: 0.01, "display heart follows the lap window")
check(storedLaps.splits[0].durationSeconds == 600, "lap rebuild does not rewrite the stored rows")

if failures.isEmpty {
    print("health-series-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
