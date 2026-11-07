import Foundation

// swiftc codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/SampleLibrary.swift codes/ios/Shared/Database.swift \
//   codes/ios/Shared/AccountIdentity.swift codes/ios/workout-delete-check/main.swift \
//   -o /tmp/workout-delete-check && /tmp/workout-delete-check

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

let start = Date(timeIntervalSince1970: 1_700_000_000)

func makeWorkout(
    id: UUID = UUID(),
    start: Date,
    distance: Double = 5_000,
    heart: Double = 150,
    healthKitUUID: String? = nil,
    origin: WorkoutOrigin = .apple,
    paceSeries: [SeriesPoint] = []
) -> WorkoutRecord {
    WorkoutRecord(
        id: id,
        sport: .running,
        start: start,
        end: start.addingTimeInterval(1_800),
        distanceMeters: distance,
        energyKilocalories: 200,
        averageHeartRate: heart,
        averageCadence: 170,
        elevationGainMeters: 20,
        route: [],
        splits: [],
        heartRate: [],
        cadenceSeries: [],
        paceSeries: paceSeries,
        stride: [],
        elevation: [],
        groundContact: [],
        power: [],
        origin: origin,
        healthKitUUID: healthKitUUID
    )
}

let healthID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
let health = makeWorkout(
    id: healthID,
    start: start.addingTimeInterval(3_600),
    distance: 10_000,
    healthKitUUID: "HK-RUN-1"
)
let localID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
let local = makeWorkout(
    id: localID,
    start: start,
    distance: 3_000,
    healthKitUUID: nil,
    origin: .simulated
)
let other = makeWorkout(
    id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
    start: start.addingTimeInterval(7_200),
    distance: 2_000,
    healthKitUUID: "HK-HIKE-2"
)
let blankHealthID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
let blankHealth = makeWorkout(
    id: blankHealthID,
    start: start.addingTimeInterval(-3_600),
    distance: 800,
    healthKitUUID: "   "
)

var database = Database()
database.workouts = [other, health, local, blankHealth]
let before = RecordStats.make(workouts: database.workouts, window: .all, now: start)
check(before.count == 4, "stats see every stored workout before a delete")
check(before.distanceMeters == 15_800, "stats distance is the sum of the same workouts")

database.deleteWorkout(id: health.id)
check(database.workouts.allSatisfy { $0.healthKitUUID != "HK-RUN-1" }, "deleted Health workout leaves the store")
check(database.deletedWorkouts.healthKitUUIDs == ["HK-RUN-1"], "Health workout is remembered by healthKitUUID")
check(!database.deletedWorkouts.localWorkoutIDs.contains(health.id), "Health workout is not remembered by record id")
check(database.workouts.contains { $0.id == local.id }, "deleting a Health workout keeps the device workout")
check(database.workouts.contains { $0.id == other.id }, "deleting one Health workout keeps the other")

database.deleteWorkout(id: local.id)
check(!database.workouts.contains { $0.id == local.id }, "device-only workout leaves the store")
check(database.deletedWorkouts.localWorkoutIDs == [local.id], "device-only workout is remembered by record id")
check(database.deletedWorkouts.healthKitUUIDs == ["HK-RUN-1"], "local delete does not drop the Health denylist")

database.deleteWorkout(id: blankHealth.id)
check(!database.workouts.contains { $0.id == blankHealth.id }, "blank Health id is removed")
check(database.deletedWorkouts.localWorkoutIDs == [local.id, blankHealth.id], "blank Health id is remembered by record id")

database.deleteWorkout(id: health.id)
check(database.deletedWorkouts.healthKitUUIDs == ["HK-RUN-1"], "deleting a missing workout does not duplicate the denylist")
check(database.workouts.count == 1 && database.workouts[0].id == other.id, "only the untouched workout remains")

let after = RecordStats.make(workouts: database.workouts, window: .all, now: start)
check(after.count == 1, "analysis summary count follows the remaining workouts")
check(after.distanceMeters == other.distanceMeters, "analysis summary distance drops the deleted workouts")
check(after.distanceMeters < before.distanceMeters, "analysis summary changes when workouts are deleted")

let replayedHealth = makeWorkout(
    id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
    start: health.start,
    distance: health.distanceMeters,
    healthKitUUID: "HK-RUN-1",
    paceSeries: [SeriesPoint(second: 30, value: 300)]
)
check(database.insertWorkout(replayedHealth) == false, "insert refuses a denylisted Health workout")
check(database.workouts.allSatisfy { $0.healthKitUUID != "HK-RUN-1" }, "refused Health insert does not reappear")

let replayedLocal = makeWorkout(
    id: local.id,
    start: local.start,
    distance: 9_999,
    healthKitUUID: nil,
    origin: .simulated
)
check(database.insertWorkout(replayedLocal) == false, "insert refuses a denylisted device workout id")
check(!database.workouts.contains { $0.id == local.id }, "refused device insert does not reappear")

let freshLocal = makeWorkout(
    id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
    start: start.addingTimeInterval(10_000),
    distance: 1_500,
    healthKitUUID: nil,
    origin: .simulated
)
check(database.insertWorkout(freshLocal) == true, "a new device workout can still be saved")
check(database.workouts.contains { $0.id == freshLocal.id }, "accepted device workout is stored")

let duplicate = makeWorkout(
    id: UUID(),
    start: other.start.addingTimeInterval(10),
    distance: 50,
    healthKitUUID: "HK-HIKE-2"
)
let countBeforeDuplicate = database.workouts.count
check(database.insertWorkout(duplicate) == false, "insert still refuses an existing Health uuid")
check(database.workouts.count == countBeforeDuplicate, "duplicate Health uuid does not append")
check(
    database.workouts.first { $0.healthKitUUID == "HK-HIKE-2" }?.distanceMeters == other.distanceMeters,
    "duplicate Health uuid keeps the stored row"
)

var replaced = freshLocal
replaced.distanceMeters = 1_700
check(database.insertWorkout(replaced) == true, "insert still replaces a stored device workout with the same id")
check(
    database.workouts.first { $0.id == freshLocal.id }?.distanceMeters == 1_700,
    "same-id device insert updates the stored row"
)

var rows = database.workouts
let richerOther = makeWorkout(
    id: UUID(),
    start: other.start,
    distance: other.distanceMeters,
    healthKitUUID: "HK-HIKE-2",
    paceSeries: [SeriesPoint(second: 30, value: 360)]
)
WorkoutImport.merge([replayedHealth, richerOther], into: &rows, skipping: database.deletedWorkouts)
check(rows.allSatisfy { $0.healthKitUUID != "HK-RUN-1" }, "import does not bring back a denylisted Health workout")
check(
    rows.first { $0.healthKitUUID == "HK-HIKE-2" }?.paceSeries == richerOther.paceSeries,
    "import still fills a Health workout that was not deleted"
)
check(rows.contains { $0.id == freshLocal.id }, "import keeps a device workout that was not deleted")

var stillListed = [health, other]
WorkoutImport.merge([replayedHealth], into: &stillListed, skipping: database.deletedWorkouts)
check(stillListed.allSatisfy { $0.id != health.id }, "import drops a denylisted Health row that was still stored")
check(stillListed.contains { $0.id == other.id }, "import keeps the Health row that is not denylisted")
check(stillListed.allSatisfy { $0.paceSeries.isEmpty }, "a denylisted Health row is not refreshed before it is dropped")

var freshImport: [WorkoutRecord] = []
WorkoutImport.merge([replayedHealth], into: &freshImport)
check(freshImport.contains { $0.healthKitUUID == "HK-RUN-1" }, "import without a denylist still appends")

var seededRows = [
    makeWorkout(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        start: start,
        healthKitUUID: "seed",
        origin: .sample
    )
]
WorkoutImport.merge([other], into: &seededRows, skipping: database.deletedWorkouts)
check(seededRows.allSatisfy { !SampleLibrary.isSeededWorkout($0) }, "denylist import still drops seeded workouts")
check(seededRows.contains { $0.healthKitUUID == "HK-HIKE-2" }, "denylist import still appends a new Health workout")

let twinID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
var twins = Database()
twins.workouts = [
    health,
    makeWorkout(id: twinID, start: health.start.addingTimeInterval(-10), distance: 100, healthKitUUID: "HK-RUN-1")
]
twins.deleteWorkout(id: health.id)
check(twins.workouts.isEmpty, "deleting a Health workout removes every row with that healthKitUUID")
check(twins.deletedWorkouts.healthKitUUIDs == ["HK-RUN-1"], "twin Health rows share one denylist entry")

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

do {
    let data = try encoder.encode(database)
    var decoded = try decoder.decode(Database.self, from: data)
    check(decoded.deletedWorkouts.healthKitUUIDs == database.deletedWorkouts.healthKitUUIDs, "Health denylist round-trips")
    check(decoded.deletedWorkouts.localWorkoutIDs == database.deletedWorkouts.localWorkoutIDs, "device denylist round-trips")
    check(decoded.workouts.allSatisfy { $0.healthKitUUID != "HK-RUN-1" }, "saved file does not contain the deleted Health workout")
    check(decoded.insertWorkout(replayedHealth) == false, "a reloaded denylist still refuses the Health workout")

    let legacyWorkout = """
    {"id":"11111111-1111-1111-1111-111111111111","sport":"running","start":"2026-01-01T00:00:00Z","end":"2026-01-01T00:30:00Z","distanceMeters":1000,"energyKilocalories":50,"averageHeartRate":140,"averageCadence":170,"elevationGainMeters":12,"route":[],"splits":[],"heartRate":[],"cadenceSeries":[],"paceSeries":[],"stride":[],"elevation":[],"groundContact":[],"power":[],"origin":"apple","healthKitUUID":"legacy-hk"}
    """
    let legacyDatabase = try decoder.decode(Database.self, from: Data("{\"workouts\":[\(legacyWorkout)]}".utf8))
    check(legacyDatabase.workouts.count == 1, "phone file without deletedWorkouts still loads")
    check(legacyDatabase.workouts[0].healthKitUUID == "legacy-hk", "legacy workout survives the new key")
    check(legacyDatabase.deletedWorkouts.healthKitUUIDs.isEmpty, "missing deletedWorkouts decodes as an empty Health denylist")
    check(legacyDatabase.deletedWorkouts.localWorkoutIDs.isEmpty, "missing deletedWorkouts decodes as an empty device denylist")

    let partial = try decoder.decode(
        Database.self,
        from: Data("{\"deletedWorkouts\":{\"healthKitUUIDs\":[\"only-health\"]}}".utf8)
    )
    check(partial.deletedWorkouts.healthKitUUIDs == ["only-health"], "partial denylist keeps the Health ids")
    check(partial.deletedWorkouts.localWorkoutIDs.isEmpty, "partial denylist defaults the missing device ids")
    check(partial.workouts.isEmpty, "partial denylist does not invent workouts")

    let emptyObject = try decoder.decode(Database.self, from: Data("{\"deletedWorkouts\":{}}".utf8))
    check(emptyObject.deletedWorkouts.healthKitUUIDs.isEmpty && emptyObject.deletedWorkouts.localWorkoutIDs.isEmpty, "empty denylist object decodes")

    AppFiles.save(decoded, name: "workout-delete-check.json")
    let loaded = AppFiles.load("workout-delete-check.json")
    check(loaded?.deletedWorkouts.healthKitUUIDs == ["HK-RUN-1"], "phone.json keeps the Health denylist")
    check(loaded?.deletedWorkouts.localWorkoutIDs.contains(local.id) == true, "phone.json keeps the device denylist")
    check(loaded?.workouts.contains { $0.id == health.id } == false, "phone.json does not restore the deleted workout")
    if var loaded {
        var imported = loaded.workouts
        WorkoutImport.merge([replayedHealth], into: &imported, skipping: loaded.deletedWorkouts)
        check(imported.allSatisfy { $0.healthKitUUID != "HK-RUN-1" }, "import after reload keeps the deleted Health workout gone")
        check(loaded.insertWorkout(replayedHealth) == false, "add path after reload refuses the denylisted Health workout")
    } else {
        check(false, "phone.json failed to load")
    }
} catch {
    check(false, "denylist coding failed: \(error)")
}

check(
    RecordCardSwipe.restingOffset(base: 0, translation: -200, predicted: -400, revealed: 80) == -80,
    "a full swipe only reveals the delete button"
)
check(
    RecordCardSwipe.restingOffset(base: 0, translation: -10, predicted: -12, revealed: 80) == 0,
    "a short swipe stays closed"
)
check(
    RecordCardSwipe.restingOffset(base: -80, translation: 70, predicted: 90, revealed: 80) == 0,
    "dragging the open card back closes it"
)
check(
    RecordCardSwipe.restingOffset(base: 0, translation: -30, predicted: -120, revealed: 80) == -80,
    "a flick reveals the delete button"
)
check(
    RecordCardSwipe.restingOffset(base: 0, translation: 40, predicted: 80, revealed: 80) == 0,
    "a rightward swipe does not reveal delete"
)

if failures.isEmpty {
    print("workout-delete-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
