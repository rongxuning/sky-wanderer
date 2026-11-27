import Foundation

// swiftc codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/ZoneDwell.swift \
//   codes/ios/Shared/SampleLibrary.swift codes/ios/Shared/Database.swift \
//   codes/ios/Shared/AccountIdentity.swift codes/ios/Shared/Formatting.swift \
//   codes/ios/Shared/WorkoutTrackStore.swift \
//   codes/ios/workout-track-store-check/main.swift \
//   -o /tmp/workout-track-store-check && /tmp/workout-track-store-check

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

func near(_ a: Double, _ b: Double, _ eps: Double, _ message: String) {
    check(abs(a - b) <= eps, message)
}

check(WorkoutTrackStore.summaryLimit == 64, "list summary keeps at most 64 points")
check(WorkoutTrackStore.folder == "workout-tracks", "tracks live under workout-tracks")
check(
    WorkoutTrackStore.filename(for: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        == "workout-tracks/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json",
    "per-workout track filename uses the workout id"
)

let short = (0..<12).map { index in
    GeoPoint(latitude: 31.2 + Double(index) * 0.001, longitude: 121.5, altitude: 10, timestamp: nil)
}
check(WorkoutTrackStore.summarize(short).count == 12, "short tracks are not padded or trimmed")

let long = (0..<400).map { index in
    GeoPoint(
        latitude: 31.0 + Double(index) * 0.0001,
        longitude: 121.0 + Double(index) * 0.0001,
        altitude: Double(index),
        timestamp: nil
    )
}
let summary = WorkoutTrackStore.summarize(long)
check(summary.count == WorkoutTrackStore.summaryLimit, "long tracks compress to the summary limit")
near(summary.first!.latitude, long.first!.latitude, 0.0000001, "summary keeps the start")
near(summary.last!.latitude, long.last!.latitude, 0.0000001, "summary keeps the end")

let workoutID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
WorkoutTrackStore.delete(workoutID: workoutID)

var record = WorkoutRecord(
    id: workoutID,
    sport: .outdoorRunning,
    start: Date(timeIntervalSince1970: 1_700_000_000),
    end: Date(timeIntervalSince1970: 1_700_001_800),
    distanceMeters: 5_000,
    energyKilocalories: 200,
    averageHeartRate: 150,
    averageCadence: 170,
    elevationGainMeters: 20,
    route: long,
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
check(record.listRouteCount == 400, "listRouteCount falls back to embedded route length")

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

var decoded = try! decoder.decode(WorkoutRecord.self, from: try! encoder.encode(record))
check(decoded.route.count == 400, "legacy decode keeps a full embedded route")
check(decoded.routePointCount == 400, "missing routePointCount defaults to route.count")
check(decoded.routeTrackFilename == nil, "legacy rows have no side file yet")

check(WorkoutTrackStore.detach(&decoded), "detach moves a long track out of the record")
check(decoded.route.count == WorkoutTrackStore.summaryLimit, "detach leaves a list summary")
check(decoded.routePointCount == 400, "detach keeps the full point count")
check(decoded.routeTrackFilename == WorkoutTrackStore.filename(for: workoutID), "detach writes the side file name")
check(decoded.listRouteCount == 400, "list chrome uses the full count after detach")

let restored = WorkoutTrackStore.points(for: decoded)
check(restored.count == 400, "points(for:) reloads the full track")
near(restored[200].latitude, long[200].latitude, 0.0000001, "reloaded mid point matches")

check(!WorkoutTrackStore.detach(&decoded), "second detach is a no-op when already stored")

var workouts = [decoded]
workouts[0].route = long
workouts[0].routeTrackFilename = nil
workouts[0].routePointCount = 0
check(WorkoutTrackStore.migrate(&workouts), "migrate detaches long embedded routes")
check(workouts[0].route.count == WorkoutTrackStore.summaryLimit, "migrate leaves summaries in phone.json rows")
check(WorkoutTrackStore.points(for: workouts[0]).count == 400, "migrate keeps full tracks on disk")

var database = Database()
database.seeded = true
check(database.insertWorkout(record), "insertWorkout accepts a long-track record")
let stored = database.workouts[0]
check(stored.route.count <= WorkoutTrackStore.summaryLimit, "insertWorkout stores a summary in the database")
check(stored.listRouteCount == 400, "insertWorkout preserves the full count")
check(WorkoutTrackStore.points(for: stored).count == 400, "insertWorkout keeps the full track loadable")

database.deleteWorkout(id: workoutID)
check(database.workouts.isEmpty, "deleteWorkout removes the row")
check(WorkoutTrackStore.load(filename: WorkoutTrackStore.filename(for: workoutID)) == nil, "deleteWorkout removes the side file")

if failures.isEmpty {
    print("workout-track-store-check: ok")
    exit(0)
}

print("workout-track-store-check failed:")
for failure in failures {
    print("- \(failure)")
}
exit(1)
