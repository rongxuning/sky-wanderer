import Foundation

// swiftc codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/SampleLibrary.swift codes/ios/Shared/HealthSeries.swift \
//   codes/ios/Shared/Database.swift codes/ios/Shared/AccountIdentity.swift \
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

    let legacyDatabase = try decoder.decode(Database.self, from: Data("{\"workouts\":[\(legacy)]}".utf8))
    check(legacyDatabase.workouts.count == 1, "phone file without the new key still loads")
    check(legacyDatabase.workouts[0].verticalOscillation.isEmpty, "loaded workout defaults the new series")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(imported)
    var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    check(object["verticalOscillation"] != nil, "encoder writes verticalOscillation")
    object.removeValue(forKey: "verticalOscillation")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try decoder.decode(WorkoutRecord.self, from: stripped)
    check(decoded.verticalOscillation.isEmpty, "stripped key defaults to []")
    check(decoded.power == imported.power, "other series survive a missing key")
    let roundTrip = try decoder.decode(WorkoutRecord.self, from: encoded)
    check(roundTrip.verticalOscillation == oscillation, "present vertical oscillation round-trips")
} catch {
    check(false, "legacy workout failed to decode: \(error)")
}

if failures.isEmpty {
    print("health-series-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
