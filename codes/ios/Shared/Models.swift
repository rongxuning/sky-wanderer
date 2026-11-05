import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

enum SportKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case hiking
    case running

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hiking: return "徒步"
        case .running: return "跑步"
        }
    }

    /// Used by the session-load formula. Documented in `TrainingEstimate`.
    var loadFactor: Double {
        switch self {
        case .hiking: return 0.8
        case .running: return 1.0
        }
    }
}

struct GeoPoint: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var timestamp: Date?

    #if canImport(CoreLocation)
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    #endif

    func moved(northMeters: Double, eastMeters: Double) -> GeoPoint {
        let lat = latitude + northMeters / 111_320
        let lon = longitude + eastMeters / (111_320 * cos(latitude * .pi / 180))
        return GeoPoint(latitude: lat, longitude: lon, altitude: altitude, timestamp: timestamp)
    }
}

enum LiveBlock: String, Codable, Hashable, CaseIterable, Identifiable {
    case map
    case distance
    case pace
    case heartRate
    case cadence
    case splits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: return "运动地图及轨迹"
        case .distance: return "总距离"
        case .pace: return "当前配速"
        case .heartRate: return "实时心率"
        case .cadence: return "实时步频"
        case .splits: return "每公里配速"
        }
    }

    var isCompact: Bool {
        switch self {
        case .pace, .heartRate, .cadence: return true
        case .map, .distance, .splits: return false
        }
    }

    static let standard: [LiveBlock] = [.map, .distance, .pace, .heartRate, .cadence, .splits]
}

enum WorkoutOrigin: String, Codable, Hashable {
    case sample
    case apple
    case simulated

    var label: String {
        switch self {
        case .sample: return "示例"
        case .apple: return "Apple"
        case .simulated: return "本地模拟"
        }
    }
}

struct SeriesPoint: Codable, Hashable, Identifiable {
    var second: Double
    var value: Double
    var id: Double { second }
}

struct KilometerSplit: Codable, Hashable, Identifiable {
    var index: Int
    var paceSecPerKm: Double
    var cadence: Double
    var heartRate: Double
    var partial: Bool

    var id: Int { index }
}

struct WorkoutRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var sport: SportKind
    var start: Date
    var end: Date
    var distanceMeters: Double
    var energyKilocalories: Double
    var averageHeartRate: Double
    var averageCadence: Double
    var elevationGainMeters: Double
    var route: [GeoPoint]
    var splits: [KilometerSplit]
    var heartRate: [SeriesPoint]
    var cadenceSeries: [SeriesPoint]
    var paceSeries: [SeriesPoint]
    var stride: [SeriesPoint]
    var elevation: [SeriesPoint]
    var groundContact: [SeriesPoint]
    var power: [SeriesPoint]
    /// Millimeters. Missing in phone files saved before this series was imported.
    var verticalOscillation: [SeriesPoint] = []
    var origin: WorkoutOrigin
    var healthKitUUID: String?

    var duration: TimeInterval { end.timeIntervalSince(start) }

    var averagePaceSecPerKm: Double {
        guard distanceMeters > 1 else { return 0 }
        return duration / (distanceMeters / 1000)
    }

    var sessionLoad: Int {
        TrainingEstimate.sessionLoad(duration: duration, averageHeartRate: averageHeartRate, sport: sport)
    }

    /// Steps per minute for the record card.
    /// Prefers the stored average, then a mean of the cadence series, then split cadence.
    /// Health imports often leave `averageCadence` at 0 even when a series or later import has steps.
    var resolvedAverageCadence: Double {
        if averageCadence > 0 { return averageCadence }
        let series = cadenceSeries.map(\.value).filter { $0 > 0 }
        if !series.isEmpty {
            return series.reduce(0, +) / Double(series.count)
        }
        let fromSplits = splits.map(\.cadence).filter { $0 > 0 }
        if !fromSplits.isEmpty {
            return fromSplits.reduce(0, +) / Double(fromSplits.count)
        }
        return 0
    }

    /// Meters per step.
    /// Uses a time-weighted mean of `stride` when that series has samples.
    /// Otherwise derives stride from speed and cadence: (1000 / pace) / (cadence / 60).
    /// Returns 0 when neither source exists, or the result is outside 0.30–2.20 m
    /// (HealthKit imports often store an empty stride series and cadence 0).
    var averageStrideMeters: Double {
        let samples = stride.filter { $0.value > 0 }.sorted { $0.second < $1.second }
        let measured: Double
        if samples.count >= 2 {
            var area = 0.0
            var span = 0.0
            for index in 1..<samples.count {
                let dt = samples[index].second - samples[index - 1].second
                guard dt > 0 else { continue }
                area += (samples[index].value + samples[index - 1].value) / 2 * dt
                span += dt
            }
            if span > 0 {
                measured = area / span
            } else {
                measured = samples.reduce(0) { $0 + $1.value } / Double(samples.count)
            }
        } else if let only = samples.first {
            measured = only.value
        } else {
            let pace = averagePaceSecPerKm
            let cadence = resolvedAverageCadence
            guard cadence > 30, pace > 0, pace < 3_600 else { return 0 }
            let metersPerSecond = 1000 / pace
            measured = metersPerSecond / (cadence / 60)
        }
        guard measured >= 0.30, measured <= 2.20 else { return 0 }
        return measured
    }
}

struct Account: Hashable, Identifiable {
    var id: UUID
    /// Display name. Kept as `name` so existing screens stay valid.
    var name: String
    var email: String
    var passwordHash: String
    /// JPEG in app support. The account service does not store this file.
    var avatarFilename: String? = nil
    var createdAt: Date = Date()
    /// Set when this account was merged into an earlier one and must not be used.
    var retiredAt: Date?
    var mergedIntoUserID: UUID?
    var mergedFromUserIDs: [UUID] = []

    var displayName: String { name }
}

extension Account: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, email, passwordHash, avatarFilename, createdAt, retiredAt, mergedIntoUserID, mergedFromUserIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        passwordHash = try container.decodeIfPresent(String.self, forKey: .passwordHash) ?? ""
        avatarFilename = try container.decodeIfPresent(String.self, forKey: .avatarFilename)
        // Stored as a numeric timestamp so two accounts created in the same second
        // still merge toward the earlier one after the JSON file is reloaded.
        // Accounts saved before identities existed have no timestamp and sort first.
        if let seconds = try container.decodeIfPresent(Double.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: seconds)
        } else {
            createdAt = Date(timeIntervalSince1970: 0)
        }
        if let seconds = try container.decodeIfPresent(Double.self, forKey: .retiredAt) {
            retiredAt = Date(timeIntervalSince1970: seconds)
        } else {
            retiredAt = nil
        }
        mergedIntoUserID = try container.decodeIfPresent(UUID.self, forKey: .mergedIntoUserID)
        mergedFromUserIDs = try container.decodeIfPresent([UUID].self, forKey: .mergedFromUserIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(passwordHash, forKey: .passwordHash)
        try container.encodeIfPresent(avatarFilename, forKey: .avatarFilename)
        try container.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        if let retiredAt {
            try container.encode(retiredAt.timeIntervalSince1970, forKey: .retiredAt)
        }
        try container.encodeIfPresent(mergedIntoUserID, forKey: .mergedIntoUserID)
        try container.encode(mergedFromUserIDs, forKey: .mergedFromUserIDs)
    }
}

struct SocialPost: Codable, Hashable, Identifiable {
    var id: UUID
    var author: String
    var isMine: Bool
    var createdAt: Date
    var sport: SportKind
    var distanceMeters: Double
    var duration: TimeInterval
    var paceSecPerKm: Double
    var energyKilocalories: Double
    var text: String
    var imageFilename: String?
    var route: [GeoPoint]
}

struct TeammateProfile: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct TeammateLive: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var paceSecPerKm: Double
    var heartRate: Double

    #if canImport(CoreLocation)
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    #endif
}

extension WorkoutRecord {
    private enum CodingKeys: String, CodingKey {
        case id, sport, start, end, distanceMeters, energyKilocalories
        case averageHeartRate, averageCadence, elevationGainMeters
        case route, splits, heartRate, cadenceSeries, paceSeries
        case stride, elevation, groundContact, power, verticalOscillation
        case origin, healthKitUUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sport = try container.decode(SportKind.self, forKey: .sport)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        distanceMeters = try container.decode(Double.self, forKey: .distanceMeters)
        energyKilocalories = try container.decode(Double.self, forKey: .energyKilocalories)
        averageHeartRate = try container.decode(Double.self, forKey: .averageHeartRate)
        averageCadence = try container.decode(Double.self, forKey: .averageCadence)
        elevationGainMeters = try container.decode(Double.self, forKey: .elevationGainMeters)
        route = try container.decode([GeoPoint].self, forKey: .route)
        splits = try container.decode([KilometerSplit].self, forKey: .splits)
        heartRate = try container.decode([SeriesPoint].self, forKey: .heartRate)
        cadenceSeries = try container.decode([SeriesPoint].self, forKey: .cadenceSeries)
        paceSeries = try container.decode([SeriesPoint].self, forKey: .paceSeries)
        stride = try container.decode([SeriesPoint].self, forKey: .stride)
        elevation = try container.decode([SeriesPoint].self, forKey: .elevation)
        groundContact = try container.decode([SeriesPoint].self, forKey: .groundContact)
        power = try container.decode([SeriesPoint].self, forKey: .power)
        verticalOscillation = try container.decodeIfPresent([SeriesPoint].self, forKey: .verticalOscillation) ?? []
        origin = try container.decode(WorkoutOrigin.self, forKey: .origin)
        healthKitUUID = try container.decodeIfPresent(String.self, forKey: .healthKitUUID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sport, forKey: .sport)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(distanceMeters, forKey: .distanceMeters)
        try container.encode(energyKilocalories, forKey: .energyKilocalories)
        try container.encode(averageHeartRate, forKey: .averageHeartRate)
        try container.encode(averageCadence, forKey: .averageCadence)
        try container.encode(elevationGainMeters, forKey: .elevationGainMeters)
        try container.encode(route, forKey: .route)
        try container.encode(splits, forKey: .splits)
        try container.encode(heartRate, forKey: .heartRate)
        try container.encode(cadenceSeries, forKey: .cadenceSeries)
        try container.encode(paceSeries, forKey: .paceSeries)
        try container.encode(stride, forKey: .stride)
        try container.encode(elevation, forKey: .elevation)
        try container.encode(groundContact, forKey: .groundContact)
        try container.encode(power, forKey: .power)
        try container.encode(verticalOscillation, forKey: .verticalOscillation)
        try container.encode(origin, forKey: .origin)
        try container.encodeIfPresent(healthKitUUID, forKey: .healthKitUUID)
    }
}

struct AthleteSnapshot {
    var latitude: Double
    var longitude: Double
    var paceSecPerKm: Double
    var heartRate: Double
    var date: Date
}

struct TeamSessionContext {
    var teamID: UUID
    var sport: SportKind
    var members: [TeammateProfile]
}

struct PlannedRoute: Identifiable, Hashable {
    var id: String
    var name: String
    var points: [GeoPoint]

    static let free = PlannedRoute(id: "free", name: "自由", points: [])
}

/// A route kept on this device. There is no server.
struct SavedRoute: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var points: [GeoPoint]
    var kind: Kind
    /// When a GPX file was imported on this phone. The built-in preset has none.
    var importedAt: Date?
    /// Person named in the GPX. Empty when the file does not say.
    var creator: String

    enum Kind: String, Codable {
        /// The one running route the phone editor can change.
        case presetRunning
        case gpx
    }

    static let presetRunningID = "preset-running"
    static let sampleGPXID = "sample-xuhui-riverside"

    init(
        id: String,
        name: String,
        points: [GeoPoint],
        kind: Kind,
        importedAt: Date? = nil,
        creator: String = ""
    ) {
        self.id = id
        self.name = name
        self.points = points
        self.kind = kind
        self.importedAt = importedAt
        self.creator = creator
    }

    var creatorLabel: String {
        let trimmed = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, points, kind, importedAt, creator
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        points = try container.decode([GeoPoint].self, forKey: .points)
        kind = try container.decode(Kind.self, forKey: .kind)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        creator = try container.decodeIfPresent(String.self, forKey: .creator) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(points, forKey: .points)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(importedAt, forKey: .importedAt)
        try container.encode(creator, forKey: .creator)
    }
}

struct TrainingStats {
    var distanceMeters: Double
    var averageHeartRate: Double
    var elevationGainMeters: Double
    var averageCadence: Double
    var count: Int
    /// Seconds per kilometer across the window. 0 when distance is missing.
    var averagePaceSecPerKm: Double
    /// Meters per step. 0 when stride cannot be measured or derived.
    var averageStrideMeters: Double
    /// Arithmetic mean of per-session load, including sessions whose load is 0.
    var averageSessionLoad: Double
    /// Sum of per-session load in the window.
    var totalSessionLoad: Double
    /// Placeholder 训练评分 until a score is stored.
    /// Duration-weighted mean of heart-rate intensity (HR / 180, capped at 100).
    /// 0 when no workout in the window has a heart rate.
    var trainingScore: Double

    static let empty = TrainingStats(
        distanceMeters: 0,
        averageHeartRate: 0,
        elevationGainMeters: 0,
        averageCadence: 0,
        count: 0,
        averagePaceSecPerKm: 0,
        averageStrideMeters: 0,
        averageSessionLoad: 0,
        totalSessionLoad: 0,
        trainingScore: 0
    )
}

enum StatsWindow: String, CaseIterable, Identifiable {
    case week = "周"
    case month = "月"
    case year = "年"
    case all = "总"
    var id: String { rawValue }
}

/// Turns a raw cadence quantity or a step count into steps per minute.
/// Values outside a walking/running band are treated as missing so the UI can show 「—」.
enum CadenceMath {
    static func stepsPerMinute(from raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 0 }
        let perMinute = raw < 10 ? raw * 60 : raw
        guard perMinute >= 40, perMinute <= 250 else { return 0 }
        return perMinute
    }

    static func stepsPerMinute(steps: Double, duration: TimeInterval) -> Double {
        guard steps > 0, duration > 0 else { return 0 }
        return stepsPerMinute(from: steps / (duration / 60))
    }
}

enum WorkoutImport {
    /// Appends new Health workouts and fills cadence or series an earlier import left empty.
    /// A later import that only has empty series does not clear a richer row.
    /// Drops bundled sample workouts, including the fixed sample ids, so the list keeps real sessions.
    static func merge(_ imported: [WorkoutRecord], into workouts: inout [WorkoutRecord]) {
        for record in imported {
            guard let healthID = record.healthKitUUID else { continue }
            if let index = workouts.firstIndex(where: { $0.healthKitUUID == healthID }) {
                workouts[index] = merging(workouts[index], with: record)
                continue
            }
            workouts.append(record)
        }
        workouts.removeAll { SampleLibrary.isSeededWorkout($0) }
        workouts.sort { $0.start > $1.start }
    }

    static func merging(_ existing: WorkoutRecord, with imported: WorkoutRecord) -> WorkoutRecord {
        var merged = existing
        if merged.resolvedAverageCadence <= 0, imported.averageCadence > 0 {
            merged.averageCadence = imported.averageCadence
        }
        fill(&merged.splits, imported.splits)
        fill(&merged.heartRate, imported.heartRate)
        fill(&merged.cadenceSeries, imported.cadenceSeries)
        fill(&merged.paceSeries, imported.paceSeries)
        fill(&merged.stride, imported.stride)
        fill(&merged.elevation, imported.elevation)
        fill(&merged.groundContact, imported.groundContact)
        fill(&merged.power, imported.power)
        fill(&merged.verticalOscillation, imported.verticalOscillation)
        return merged
    }

    private static func fill<T>(_ existing: inout [T], _ incoming: [T]) {
        if existing.isEmpty, !incoming.isEmpty {
            existing = incoming
        }
    }
}
