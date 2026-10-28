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
}

extension Database: Codable {
    private enum CodingKeys: String, CodingKey {
        case accounts, identities, authSessions, authRecords, sessionAccountID, sessionToken
        case workouts, posts, metricOrder, selectedTeammateIDs, seeded, routes
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
