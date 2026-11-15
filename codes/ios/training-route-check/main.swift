import Foundation

// swiftc -swift-version 5 codes/ios/Shared/Models.swift codes/ios/Shared/SampleLibrary.swift \
//   codes/ios/Shared/AccountIdentity.swift codes/ios/Shared/Database.swift \
//   codes/ios/Shared/TrainingEstimate.swift codes/ios/Shared/ZoneDwell.swift \
//   codes/ios/Shared/GPXFile.swift \
//   codes/ios/Shared/Formatting.swift codes/ios/Shared/RouteStats.swift \
//   codes/ios/Shared/RouteGPXStore.swift \
//   codes/ios/sky-wanderer/PlannedRouteProgress.swift \
//   codes/ios/training-route-check/main.swift \
//   -o /tmp/training-route-check && /tmp/training-route-check

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

func point(_ east: Double, _ north: Double, _ altitude: Double) -> GeoPoint {
    var placed = GeoPoint(latitude: 0, longitude: 0, altitude: altitude, timestamp: nil)
        .moved(northMeters: north, eastMeters: east)
    placed.altitude = altitude
    return placed
}

let start = point(0, 0, 100)
let mid = point(1_000, 0, 180)
let end = point(2_000, 0, 120)
let line = [start, mid, end]

let saved = SavedRoute(
    id: "riverside",
    name: "滨江",
    points: line,
    kind: .gpx,
    importedAt: Date(timeIntervalSince1970: 1_700_000_000),
    creator: "阿宁"
)

// MARK: - Draft route vs 自由跑

let chosenID = TrainingRouteDraft.selecting(saved)
check(chosenID == saved.id, "choosing an imported route stores that route id")
let chosen = TrainingRouteDraft.planned(routeID: chosenID, saved: [saved], workouts: [])
check(chosen.id == saved.id, "the draft resolves the selected route")
check(chosen.points == line, "the start map gets that route's polyline")
check(chosen.name == "滨江", "the draft keeps the route name")

let freeID = TrainingRouteDraft.freeRunID()
check(freeID == PlannedRoute.free.id, "自由跑 uses the free route id")
let freed = TrainingRouteDraft.planned(routeID: freeID, saved: [saved], workouts: [])
check(freed == PlannedRoute.free, "自由跑 drops the planned polyline")
check(freed.points.isEmpty, "自由跑 has no planned points")

let unknown = TrainingRouteDraft.planned(routeID: "missing", saved: [saved], workouts: [])
check(unknown == PlannedRoute.free, "an unknown id is a free run")

let workoutID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
let workoutRoute = [start, end]
let workout = WorkoutRecord(
    id: workoutID,
    sport: .hiking,
    start: Date(timeIntervalSince1970: 1_700_000_000),
    end: Date(timeIntervalSince1970: 1_700_003_600),
    distanceMeters: 2_000,
    energyKilocalories: 0,
    averageHeartRate: 0,
    averageCadence: 0,
    elevationGainMeters: 20,
    route: workoutRoute,
    splits: [],
    heartRate: [],
    cadenceSeries: [],
    paceSeries: [],
    stride: [],
    elevation: [],
    groundContact: [],
    power: [],
    origin: .simulated
)
let fromWorkout = TrainingRouteDraft.planned(routeID: workoutID.uuidString, saved: [], workouts: [workout])
check(fromWorkout.points == workoutRoute, "a saved workout id still supplies its track")
check(fromWorkout.id == workoutID.uuidString, "the workout id stays on the planned route")

let importedWins = TrainingRouteDraft.planned(routeID: saved.id, saved: [saved], workouts: [workout])
check(importedWins.points == line, "an imported route wins over a workout with another id")

// Hiking and running share this choice. The id is not tied to a sport.
check(
    TrainingRouteDraft.planned(routeID: saved.id, saved: [saved], workouts: []).points.count == 3,
    "the same planned polyline is available for hiking and running"
)

// MARK: - Planned elevation profile

let samples = PlannedRouteProgress.profileSamples(line)
check(samples.count == 3, "the full planned profile keeps every point of a short route")
near(samples[0].distanceKilometers, 0, 0.0001, "profile starts at zero kilometers")
near(samples[0].changeMeters, 0, 0.001, "profile starts at the first altitude")
near(samples[1].distanceKilometers, 1, 0.02, "midpoint is one kilometer along")
near(samples[1].changeMeters, 80, 0.001, "midpoint is 80 meters above the start")
near(samples[2].distanceKilometers, 2, 0.02, "finish is two kilometers along")
near(samples[2].changeMeters, 20, 0.001, "finish is 20 meters above the start")
check(
    PlannedRouteProgress.axisLabel(distanceKilometers: samples[1].distanceKilometers)
        == Format.kilometers(samples[1].distanceKilometers * 1000),
    "the profile x-axis uses Format.kilometers"
)
check(PlannedRouteProgress.axisLabel(distanceKilometers: 1) == "1.00", "one kilometer formats as 1.00")
check(PlannedRouteProgress.axisLabel(distanceKilometers: 0) == "0.00", "zero kilometers formats as 0.00")
check(PlannedRouteProgress.profileSamples([]).isEmpty, "a free run has no elevation samples")
near(
    PlannedRouteProgress.changeMeters(at: samples[1].distanceKilometers, samples: samples),
    samples[1].changeMeters,
    0.001,
    "the progress marker sits on the profile"
)
let halfway = samples[1].distanceKilometers / 2
near(
    PlannedRouteProgress.changeMeters(at: halfway, samples: samples),
    samples[1].changeMeters / 2,
    0.5,
    "the marker interpolates between profile samples"
)

// MARK: - Progress and remaining distance

let total = PlannedRouteProgress.locate(athlete: nil, on: line).totalMeters
near(total, 2_000, 1, "planned length is two kilometers")

let onMid = PlannedRouteProgress.locate(athlete: mid, on: line)
near(onMid.progressedMeters, 1_000, 1, "standing on the midpoint has run half the route")
near(onMid.remainingMeters, 1_000, 1, "half the route remains")
check(!onMid.offRoute, "a point on the line is on route")
near(onMid.remainingMeters, onMid.totalMeters - onMid.progressedMeters, 0.001, "on-route remaining matches the marker")

let partial = PlannedRouteProgress.locate(athlete: point(400, 20, 100), on: line)
near(partial.progressedMeters, 400, 5, "a point partway along the first segment keeps that along-track distance")
near(partial.remainingMeters, partial.totalMeters - 400, 5, "remaining is the rest of the planned route")
check(!partial.offRoute, "20 meters of GPS noise stays on route")
near(partial.remainingMeters, partial.totalMeters - partial.progressedMeters, 0.001, "partial remaining matches the marker")

let besideMiddle = PlannedRouteProgress.locate(athlete: point(1_000, 80, 180), on: line)
near(besideMiddle.progressedMeters, 1_000, 5, "off-route beside the middle stays on that point of the plan")
near(besideMiddle.remainingMeters, besideMiddle.totalMeters - besideMiddle.progressedMeters, 0.001, "off-route remaining matches the marker")
check(besideMiddle.offRoute, "80 meters beside the line is off route")
let naiveRemaining = max(0, besideMiddle.totalMeters - 5_000)
check(
    abs(besideMiddle.remainingMeters - naiveRemaining) > 100,
    "off-route remaining is not planned total minus a longer GPS track"
)

let besideStart = PlannedRouteProgress.locate(athlete: point(0, 200, 100), on: line)
near(besideStart.progressedMeters, 0, 1, "off-route beside the start has not progressed")
near(besideStart.remainingMeters, besideStart.totalMeters, 1, "the full planned route remains")
check(besideStart.offRoute, "200 meters off the start is off route")
check(
    abs(besideStart.remainingMeters - max(0, besideStart.totalMeters - 200)) > 100,
    "distance away from the start is not subtracted from the route"
)

let pastEnd = PlannedRouteProgress.locate(athlete: point(2_030, 0, 120), on: line)
near(pastEnd.progressedMeters, pastEnd.totalMeters, 1, "past the finish the marker is at the end")
near(pastEnd.remainingMeters, 0, 1, "nothing remains past the finish")

let waiting = PlannedRouteProgress.locate(athlete: nil, on: line)
near(waiting.progressedMeters, 0, 0.001, "no GPS fix has not progressed")
near(waiting.remainingMeters, waiting.totalMeters, 0.001, "the full route remains before the first fix")

let freeFix = PlannedRouteProgress.locate(athlete: mid, on: [])
check(freeFix.totalMeters == 0 && freeFix.progressedMeters == 0 && freeFix.remainingMeters == 0, "自由跑 has no route remaining")

if failures.isEmpty {
    print("training-route-check: ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
