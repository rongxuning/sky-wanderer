import Foundation

struct Database {
    var accounts: [Account] = []
    var identities: [AuthIdentity] = []
    var authSessions: [AuthSession] = []
    var authRecords: [AuthOwnedRecord] = []
    var sessionAccountID: UUID?
    var sessionToken: String?
    var workouts: [WorkoutRecord] = []
    var posts: [SocialPost] = []
    var metricOrder: [LiveBlock] = LiveBlock.standard
    var selectedTeammateIDs: [String] = []
    var seeded: Bool = false
    /// Planned routes saved on this device. Missing in older files.
    var routes: [SavedRoute] = []
    /// True after the bundled 徐汇滨江 sample has been retired.
    /// Older builds set this when they inserted that sample. Launches now remove it and set this so it is not inserted again.
    var sampleRouteSeeded: Bool = false
    /// Workouts the user removed on this phone. Missing in older files.
    /// Health imports are remembered by `healthKitUUID`. Device-only rows are remembered by id.
    var deletedWorkouts: WorkoutDenylist = WorkoutDenylist()
}

extension Database {
    /// Drops the workout from this device and remembers it so a later import cannot restore it.
    /// A Health row is remembered by `healthKitUUID`. A row with no Health id is remembered by its id.
    /// Does not delete the workout from HealthKit.
    mutating func deleteWorkout(id: UUID) {
        guard let workout = workouts.first(where: { $0.id == id }) else { return }
        deletedWorkouts.remember(workout)
        if let healthID = WorkoutDenylist.healthIdentity(workout.healthKitUUID) {
            workouts.removeAll { WorkoutDenylist.healthIdentity($0.healthKitUUID) == healthID }
        } else {
            workouts.removeAll { $0.id == id }
        }
    }

    /// Appends a workout unless it is denylisted or repeats a Health uuid already stored.
    /// A denylisted Health workout stays out. A denylisted device id stays out.
    @discardableResult
    mutating func insertWorkout(_ record: WorkoutRecord) -> Bool {
        if deletedWorkouts.blocks(record) { return false }
        if let healthID = record.healthKitUUID,
           workouts.contains(where: { $0.healthKitUUID == healthID }) {
            return false
        }
        var record = record
        if RecordMotivation.storedLine(record.motivationLine) == nil,
           let previous = workouts.first(where: { $0.id == record.id }) {
            record.motivationLine = RecordMotivation.storedLine(previous.motivationLine)
        }
        workouts.removeAll { $0.id == record.id }
        workouts.append(record)
        workouts.sort { $0.start > $1.start }
        RecordMotivation.assignMissing(&workouts)
        return true
    }

    /// The first-launch sample GPX. A user import uses a UUID, including one the user named 徐汇滨江.
    static func isSeededSampleRoute(_ route: SavedRoute) -> Bool {
        route.kind == .gpx && route.id == SavedRoute.sampleGPXID
    }

    /// Drops that sample and records that it must not be inserted again.
    /// Returns GPX filenames that belonged to the sample, so the caller can delete those files only.
    @discardableResult
    mutating func retireSeededSampleRoute() -> [String] {
        let filenames = routes.compactMap { route -> String? in
            guard Self.isSeededSampleRoute(route) else { return nil }
            return route.gpxFilename
        }
        routes.removeAll { Self.isSeededSampleRoute($0) }
        sampleRouteSeeded = true
        return filenames
    }
}

extension Database: Codable {
    private enum CodingKeys: String, CodingKey {
        case accounts, identities, authSessions, authRecords, sessionAccountID, sessionToken
        case workouts, posts, metricOrder, selectedTeammateIDs, seeded, routes, sampleRouteSeeded
        case deletedWorkouts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        identities = try container.decodeIfPresent([AuthIdentity].self, forKey: .identities) ?? []
        authSessions = try container.decodeIfPresent([AuthSession].self, forKey: .authSessions) ?? []
        authRecords = try container.decodeIfPresent([AuthOwnedRecord].self, forKey: .authRecords) ?? []
        sessionAccountID = try container.decodeIfPresent(UUID.self, forKey: .sessionAccountID)
        sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken)
        workouts = try container.decodeIfPresent([WorkoutRecord].self, forKey: .workouts) ?? []
        posts = try container.decodeIfPresent([SocialPost].self, forKey: .posts) ?? []
        metricOrder = try container.decodeIfPresent([LiveBlock].self, forKey: .metricOrder) ?? LiveBlock.standard
        selectedTeammateIDs = try container.decodeIfPresent([String].self, forKey: .selectedTeammateIDs) ?? []
        seeded = try container.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        routes = try container.decodeIfPresent([SavedRoute].self, forKey: .routes) ?? []
        sampleRouteSeeded = try container.decodeIfPresent(Bool.self, forKey: .sampleRouteSeeded) ?? false
        deletedWorkouts = try container.decodeIfPresent(WorkoutDenylist.self, forKey: .deletedWorkouts) ?? WorkoutDenylist()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(identities, forKey: .identities)
        try container.encode(authSessions, forKey: .authSessions)
        try container.encode(authRecords, forKey: .authRecords)
        try container.encodeIfPresent(sessionAccountID, forKey: .sessionAccountID)
        try container.encodeIfPresent(sessionToken, forKey: .sessionToken)
        try container.encode(workouts, forKey: .workouts)
        try container.encode(posts, forKey: .posts)
        try container.encode(metricOrder, forKey: .metricOrder)
        try container.encode(selectedTeammateIDs, forKey: .selectedTeammateIDs)
        try container.encode(seeded, forKey: .seeded)
        try container.encode(routes, forKey: .routes)
        try container.encode(sampleRouteSeeded, forKey: .sampleRouteSeeded)
        try container.encode(deletedWorkouts, forKey: .deletedWorkouts)
    }
}

enum AppFiles {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base.appendingPathComponent("sky-wanderer", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func file(_ name: String) throws -> URL {
        try directory().appendingPathComponent(name)
    }

    static func load(_ name: String) -> Database? {
        guard let url = try? file(name),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Database.self, from: data)
    }

    static func save(_ database: Database, name: String) {
        guard let url = try? file(name) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(database) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
