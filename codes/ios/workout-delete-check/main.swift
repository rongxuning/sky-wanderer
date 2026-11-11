import Foundation

// swiftc codes/ios/Shared/Models.swift codes/ios/Shared/TrainingEstimate.swift \
//   codes/ios/Shared/ZoneDwell.swift \
//   codes/ios/Shared/SampleLibrary.swift codes/ios/Shared/Database.swift \
//   codes/ios/Shared/AccountIdentity.swift codes/ios/Shared/Formatting.swift \
//   codes/ios/workout-delete-check/main.swift \
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
    check(legacyDatabase.workouts[0].motivationLine == nil, "a phone file without a stored line stays unassigned")
    let blankMotivation = try decoder.decode(
        WorkoutRecord.self,
        from: Data(legacyWorkout.replacingOccurrences(of: "}", with: ",\"motivationLine\":\"   \"}").utf8)
    )
    check(blankMotivation.motivationLine == nil, "a blank stored line counts as unassigned")
    var stamped = legacyDatabase.workouts[0]
    stamped.motivationLine = "晨光只沾到半面山坡"
    let stampedAgain = try decoder.decode(WorkoutRecord.self, from: encoder.encode(stamped))
    check(stampedAgain.motivationLine == "晨光只沾到半面山坡", "a stored line round-trips in phone.json")
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

check(
    RecordCardSwipe.claimsHorizontal(dx: -40, dy: 6),
    "a sideways drag past the threshold claims the swipe"
)
check(
    !RecordCardSwipe.claimsHorizontal(dx: -12, dy: 2),
    "a short sideways drag does not claim yet"
)
check(
    !RecordCardSwipe.claimsHorizontal(dx: -30, dy: 48),
    "vertical travel does not claim the swipe"
)
check(
    !RecordCardSwipe.claimsHorizontal(dx: -24, dy: -24),
    "a diagonal drag fails closed and does not claim"
)
check(
    RecordCardSwipe.yieldsToVerticalScroll(dx: -8, dy: 40),
    "vertical travel belongs to the list scroll"
)
check(
    RecordCardSwipe.yieldsToVerticalScroll(dx: -20, dy: 20),
    "a tie at the threshold belongs to the list scroll"
)
check(
    !RecordCardSwipe.yieldsToVerticalScroll(dx: -40, dy: 8),
    "a horizontal drag does not yield to the list scroll"
)
check(
    RecordCardSwipe.shouldBeginDeletePan(translationX: -16, translationY: 3, velocityX: -40, velocityY: 10),
    "a horizontal pan may begin"
)
check(
    !RecordCardSwipe.shouldBeginDeletePan(translationX: -3, translationY: 22, velocityX: -10, velocityY: 240),
    "a vertical pan does not begin"
)
check(
    !RecordCardSwipe.shouldBeginDeletePan(translationX: -9, translationY: -9, velocityX: -200, velocityY: -40),
    "a diagonal pan does not begin"
)
check(
    RecordCardSwipe.shouldBeginDeletePan(translationX: -1, translationY: 0.2, velocityX: -220, velocityY: 30),
    "a fast sideways flick may begin before the finger has traveled far"
)
let flicked = RecordCardSwipe.predictedTranslation(translation: -30, velocity: -200)
check(
    RecordCardSwipe.restingOffset(base: 0, translation: -30, predicted: flicked, revealed: 80) == -80,
    "a flick still opens the delete button"
)
let nudged = RecordCardSwipe.predictedTranslation(translation: -10, velocity: -20)
check(
    RecordCardSwipe.restingOffset(base: 0, translation: -10, predicted: nudged, revealed: 80) == 0,
    "a short slow drag stays closed"
)

var shanghai = Calendar(identifier: .gregorian)
shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
func shanghaiDate(year: Int, month: Int, day: Int) -> Date {
    shanghai.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
}
let novemberNewest = makeWorkout(start: shanghaiDate(year: 2026, month: 11, day: 2))
let novemberOlder = makeWorkout(start: shanghaiDate(year: 2026, month: 11, day: 1))
let octoberNewest = makeWorkout(start: shanghaiDate(year: 2026, month: 10, day: 31))
let monthSpans = Format.recordMonthSpans(dates: [
    novemberNewest.start,
    novemberOlder.start,
    octoberNewest.start
])
check(monthSpans.count == 2, "two year-months become two sections")
check(monthSpans.first?.title == "2026年11月", "the first section is the newest month")
check(monthSpans.first?.lowerBound == 0 && monthSpans.first?.upperBound == 2, "November's header starts at the newest record")
check(monthSpans.last?.title == "2026年10月", "the next section is the older month")
check(monthSpans.last?.lowerBound == 2, "October's header starts at October's newest record, not its oldest")
check(
    Format.recordMonthSpans(dates: [octoberNewest.start]).first?.title == Format.monthTitle(octoberNewest.start),
    "section titles match the month label"
)

let longTrack = (0..<1000).map { index in
    GeoPoint(latitude: 31 + Double(index) * 0.0001, longitude: 121, altitude: 0, timestamp: nil)
}
let simplifiedTrack = RecordTrackPath.simplified(longTrack, limit: 180)
check(simplifiedTrack.count == 180, "a long route samples down to 180 points")
check(simplifiedTrack.first == longTrack.first, "the sample keeps the start")
check(simplifiedTrack.last == longTrack.last, "the sample keeps the end")
check(RecordTrackPath.simplified(Array(longTrack.prefix(12))).count == 12, "a short route is not resampled")

func motivationID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "ABABABAB-ABAB-ABAB-ABAB-%012X", n))!
}

func motivationEditDistance(_ left: String, _ right: String) -> Int {
    let a = Array(left)
    let b = Array(right)
    if a.isEmpty { return b.count }
    var prev = Array(0...b.count)
    for (i, ca) in a.enumerated() {
        var cur = [i + 1]
        for (j, cb) in b.enumerated() {
            let cost = ca == cb ? 0 : 1
            cur.append(min(cur[j] + 1, prev[j + 1] + 1, prev[j] + cost))
        }
        prev = cur
    }
    return prev[b.count]
}

let quoteID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
let quoteAgain = RecordMotivation.line(for: quoteID)
check(quoteAgain == RecordMotivation.line(for: quoteID), "a workout id keeps the same quote")
check(RecordMotivation.lines.contains(quoteAgain), "the quote comes from the curated list")
check(
    quoteAgain == RecordMotivation.lines[RecordMotivation.index(for: quoteID.uuidString)],
    "an unused library picks by the stable hash"
)
check(RecordMotivation.lines.count >= 250, "the curated list has at least two hundred fifty lines")
check(Set(RecordMotivation.lines).count == RecordMotivation.lines.count, "the curated list has no duplicate lines")
check(
    RecordMotivation.lines.allSatisfy { line in
        (8...14).contains(line.count) && line.unicodeScalars.allSatisfy { !$0.isASCII }
    },
    "quotes stay short Chinese lines"
)
let retiredLines = [
    "山高路远，行则将至",
    "慢慢跑，也能跑很远",
    "把今天跑完，就是胜利",
    "每一步都算数",
    "出发，就是最好的开始",
    "路在脚下，心在远方",
    "不怕走得慢，只怕停下",
    "风过林间，步履更稳",
    "今天的路，是明天的风景",
    "走完这一段，再看远方",
    "山还在，人就继续走",
    "先迈出去，路会打开",
]
check(
    retiredLines.allSatisfy { old in !RecordMotivation.lines.contains(where: { $0.contains(old) }) },
    "retired lines are not reused"
)
var repeatedGram: String?
var gramOwner: [String: String] = [:]
for line in RecordMotivation.lines {
    let chars = Array(line)
    guard chars.count >= 4 else { continue }
    for index in 0...(chars.count - 4) {
        let gram = String(chars[index..<(index + 4)])
        if let other = gramOwner[gram], other != line {
            repeatedGram = gram
        }
        gramOwner[gram] = line
    }
}
check(repeatedGram == nil, "curated lines do not share a four-character phrase")
var nearPair = false
for left in 0..<RecordMotivation.lines.count {
    for right in (left + 1)..<RecordMotivation.lines.count {
        if motivationEditDistance(RecordMotivation.lines[left], RecordMotivation.lines[right]) <= 4 {
            nearPair = true
        }
    }
}
check(!nearPair, "curated lines are not near copies of each other")
let otherQuoteID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
check(
    RecordMotivation.line(for: quoteID, healthKitUUID: "HK-RUN-1")
        == RecordMotivation.line(for: otherQuoteID, healthKitUUID: "HK-RUN-1"),
    "the same Health id keeps the quote when the local id changes"
)
check(
    RecordMotivation.line(for: quoteID, healthKitUUID: "   ") == quoteAgain,
    "a blank Health id falls back to the workout id"
)
check(
    RecordMotivation.index(for: "HK-RUN-1") == RecordMotivation.index(for: "HK-RUN-1"),
    "the quote index does not use a per-process hash"
)

var picked: [String] = []
var usedLines = Set<String>()
for n in 0..<50 {
    let line = RecordMotivation.line(
        for: motivationID(n),
        healthKitUUID: n.isMultiple(of: 2) ? "HK-MOT-\(n)" : nil,
        avoiding: usedLines
    )
    picked.append(line)
    usedLines.insert(line)
}
check(
    picked[0] == RecordMotivation.line(for: motivationID(0), healthKitUUID: "HK-MOT-0"),
    "the same id picks the same line twice"
)
check(Set(picked).count == picked.count, "picking through the remaining lines does not repeat")

var forwardBatch: [WorkoutRecord] = (0..<80).map { n in
    makeWorkout(
        id: motivationID(n),
        start: start.addingTimeInterval(Double(n)),
        healthKitUUID: n.isMultiple(of: 2) ? "HK-MOT-\(n)" : nil
    )
}
var reversedBatch = Array(forwardBatch.reversed())
RecordMotivation.assignMissing(&forwardBatch)
RecordMotivation.assignMissing(&reversedBatch)
check(
    Set(forwardBatch.compactMap(\.motivationLine)).count == forwardBatch.count,
    "a batch of different ids gets different lines"
)
check(
    forwardBatch.allSatisfy { workout in
        reversedBatch.first { $0.id == workout.id }?.motivationLine == workout.motivationLine
    },
    "assignment does not depend on list order"
)
let firstPass = forwardBatch.map(\.motivationLine)
RecordMotivation.assignMissing(&forwardBatch)
check(forwardBatch.map(\.motivationLine) == firstPass, "assigning again keeps every stored line")
var grown = forwardBatch
grown.append(makeWorkout(
    id: motivationID(9_000),
    start: start.addingTimeInterval(90_000),
    healthKitUUID: "HK-MOT-NEW"
))
RecordMotivation.assignMissing(&grown)
check(
    zip(forwardBatch, grown).allSatisfy { $0.motivationLine == $1.motivationLine },
    "a new record does not change lines already stored"
)
check(
    Set(grown.compactMap(\.motivationLine)).count == grown.count,
    "the new record gets a line of its own"
)

let overflowCount = RecordMotivation.lines.count + 40
var crowd: [WorkoutRecord] = (0..<overflowCount).map { n in
    makeWorkout(
        id: motivationID(10_000 + n),
        start: start.addingTimeInterval(Double(n)),
        healthKitUUID: "HK-CROWD-\(n)"
    )
}
RecordMotivation.assignMissing(&crowd)
check(crowd.allSatisfy { ($0.motivationLine ?? "").isEmpty == false }, "every record past the library still has a line")
check(Set(crowd.map(\.motivationLine)).count == crowd.count, "records past the library still do not share a line")
check(crowd.allSatisfy { ($0.motivationLine ?? "").count <= 16 }, "overflow lines stay short")
let crowdSnapshot = crowd.map(\.motivationLine)
RecordMotivation.assignMissing(&crowd)
check(crowd.map(\.motivationLine) == crowdSnapshot, "overflow lines stay put when assigned again")
var crowdPlus = crowd
crowdPlus.append(makeWorkout(
    id: motivationID(80_000),
    start: start.addingTimeInterval(800_000),
    healthKitUUID: "HK-CROWD-EXTRA"
))
RecordMotivation.assignMissing(&crowdPlus)
check(
    zip(crowd, crowdPlus).allSatisfy { $0.motivationLine == $1.motivationLine },
    "one more record past the library leaves stored lines alone"
)

var keptRecord = makeWorkout(id: motivationID(70_001), start: start, healthKitUUID: "HK-KEEP")
keptRecord.motivationLine = RecordMotivation.lines[0]
var importedRecord = makeWorkout(id: motivationID(70_002), start: start, healthKitUUID: "HK-KEEP")
importedRecord.motivationLine = RecordMotivation.lines[1]
let mergedLine = WorkoutImport.merging(keptRecord, with: importedRecord)
check(mergedLine.motivationLine == RecordMotivation.lines[0], "merge keeps the stored line")
check(mergedLine.id == keptRecord.id, "merge still keeps the stored row")
var unassigned = makeWorkout(id: motivationID(70_003), start: start, healthKitUUID: "HK-FILL")
var importedLine = unassigned
importedLine.motivationLine = RecordMotivation.lines[2]
check(
    WorkoutImport.merging(unassigned, with: importedLine).motivationLine == RecordMotivation.lines[2],
    "merge fills a line only when the stored row has none"
)
var shelf = [keptRecord]
WorkoutImport.merge([importedRecord], into: &shelf)
check(shelf.count == 1, "reimport still updates the Health row in place")
check(shelf[0].motivationLine == RecordMotivation.lines[0], "reimport does not replace an assigned line")
check(shelf[0].id == keptRecord.id, "reimport keeps the stored id")
let extraImport = makeWorkout(id: motivationID(70_004), start: start.addingTimeInterval(10), healthKitUUID: "HK-FRESH")
WorkoutImport.merge([extraImport], into: &shelf)
check(
    shelf.first { $0.id == keptRecord.id }?.motivationLine == RecordMotivation.lines[0],
    "importing another workout leaves the stored line"
)
let freshLine = shelf.first { $0.healthKitUUID == "HK-FRESH" }?.motivationLine
check(freshLine != nil && freshLine != RecordMotivation.lines[0], "the imported workout gets its own line")
WorkoutImport.merge([extraImport], into: &shelf)
check(
    shelf.first { $0.healthKitUUID == "HK-FRESH" }?.motivationLine == freshLine,
    "importing the same workout again keeps its line"
)

var store = Database()
var device = makeWorkout(id: motivationID(70_010), start: start, healthKitUUID: nil, origin: .simulated)
check(store.insertWorkout(device), "a device workout can be stored with a line")
let deviceLine = store.workouts.first { $0.id == device.id }?.motivationLine
check(deviceLine?.isEmpty == false, "insert writes a line onto a new workout")
device.distanceMeters = 42
device.motivationLine = nil
check(store.insertWorkout(device), "replacing the same device workout still saves")
check(
    store.workouts.first { $0.id == device.id }?.motivationLine == deviceLine,
    "replacing a workout keeps the line it already had"
)
check(store.workouts.first { $0.id == device.id }?.distanceMeters == 42, "replacing a workout still updates its other fields")
var secondDevice = makeWorkout(
    id: motivationID(70_011),
    start: start.addingTimeInterval(5),
    healthKitUUID: nil,
    origin: .simulated
)
check(store.insertWorkout(secondDevice), "a second device workout can be stored")
check(
    store.workouts.first { $0.id == device.id }?.motivationLine == deviceLine,
    "saving another workout does not move the first line"
)
check(
    store.workouts.first { $0.id == secondDevice.id }?.motivationLine != deviceLine,
    "the second workout does not reuse the first line"
)

if failures.isEmpty {
    print("workout-delete-check ok")
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
