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
    /// Active energy for this kilometer, in kilocalories. `0` when that split was saved
    /// before the live screen recorded energy, or when the session had none.
    var energyKilocalories: Double

    var id: Int { index }

    init(
        index: Int,
        paceSecPerKm: Double,
        cadence: Double,
        heartRate: Double,
        partial: Bool,
        energyKilocalories: Double = 0
    ) {
        self.index = index
        self.paceSecPerKm = paceSecPerKm
        self.cadence = cadence
        self.heartRate = heartRate
        self.partial = partial
        self.energyKilocalories = energyKilocalories
    }

    private enum CodingKeys: String, CodingKey {
        case index, paceSecPerKm, cadence, heartRate, partial, energyKilocalories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        paceSecPerKm = try container.decode(Double.self, forKey: .paceSecPerKm)
        cadence = try container.decode(Double.self, forKey: .cadence)
        heartRate = try container.decode(Double.self, forKey: .heartRate)
        partial = try container.decode(Bool.self, forKey: .partial)
        energyKilocalories = try container.decodeIfPresent(Double.self, forKey: .energyKilocalories) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(paceSecPerKm, forKey: .paceSecPerKm)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(heartRate, forKey: .heartRate)
        try container.encode(partial, forKey: .partial)
        try container.encode(energyKilocalories, forKey: .energyKilocalories)
    }
}

/// Historical weather cached for one workout. A ready flag means that source
/// answered for the start hour, even when the hour itself had no number.
struct WorkoutConditions: Codable, Hashable {
    var temperatureCelsius: Double?
    var relativeHumidityPercent: Double?
    var airQualityIndex: Int?
    var airQualityGrade: String?
    var weatherReady: Bool
    var airReady: Bool

    init(
        temperatureCelsius: Double? = nil,
        relativeHumidityPercent: Double? = nil,
        airQualityIndex: Int? = nil,
        airQualityGrade: String? = nil,
        weatherReady: Bool = false,
        airReady: Bool = false
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.relativeHumidityPercent = relativeHumidityPercent
        self.airQualityIndex = airQualityIndex
        self.airQualityGrade = airQualityGrade
        self.weatherReady = weatherReady
        self.airReady = airReady
    }

    private enum CodingKeys: String, CodingKey {
        case temperatureCelsius, relativeHumidityPercent, airQualityIndex, airQualityGrade
        case weatherReady, airReady
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperatureCelsius = try container.decodeIfPresent(Double.self, forKey: .temperatureCelsius)
        relativeHumidityPercent = try container.decodeIfPresent(Double.self, forKey: .relativeHumidityPercent)
        airQualityIndex = try container.decodeIfPresent(Int.self, forKey: .airQualityIndex)
        airQualityGrade = try container.decodeIfPresent(String.self, forKey: .airQualityGrade)
        weatherReady = try container.decodeIfPresent(Bool.self, forKey: .weatherReady) ?? false
        airReady = try container.decodeIfPresent(Bool.self, forKey: .airReady) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(temperatureCelsius, forKey: .temperatureCelsius)
        try container.encodeIfPresent(relativeHumidityPercent, forKey: .relativeHumidityPercent)
        try container.encodeIfPresent(airQualityIndex, forKey: .airQualityIndex)
        try container.encodeIfPresent(airQualityGrade, forKey: .airQualityGrade)
        try container.encode(weatherReady, forKey: .weatherReady)
        try container.encode(airReady, forKey: .airReady)
    }

    /// Fills only the sources the update actually fetched.
    static func merging(_ base: WorkoutConditions?, with update: WorkoutConditions) -> WorkoutConditions {
        var result = base ?? WorkoutConditions()
        if update.weatherReady {
            result.temperatureCelsius = update.temperatureCelsius
            result.relativeHumidityPercent = update.relativeHumidityPercent
            result.weatherReady = true
        }
        if update.airReady {
            result.airQualityIndex = update.airQualityIndex
            result.airQualityGrade = update.airQualityGrade
            result.airReady = true
        }
        return result
    }
}

/// Cached reverse-geocode of the first route point. Presence means the lookup finished.
struct WorkoutStartPlace: Codable, Hashable {
    var name: String?
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
    /// Moving seconds, excluding pauses. `0` or a missing key means unknown.
    var trainingDurationSeconds: TimeInterval = 0
    var conditions: WorkoutConditions?
    var startPlace: WorkoutStartPlace?

    /// Wall-clock span from `start` to `end`, including any pauses.
    var elapsedDuration: TimeInterval { end.timeIntervalSince(start) }

    /// Moving time. Unknown or implausible stored values fall back to elapsed time,
    /// so records saved before this field existed keep their old pace and load.
    var trainingDuration: TimeInterval {
        let elapsed = elapsedDuration
        guard trainingDurationSeconds.isFinite,
              trainingDurationSeconds > 0,
              elapsed.isFinite,
              trainingDurationSeconds <= elapsed else {
            return elapsed
        }
        return trainingDurationSeconds
    }

    /// Elapsed wall-clock time. Pace, load, and list cards use `trainingDuration`.
    var duration: TimeInterval { elapsedDuration }

    var averagePaceSecPerKm: Double {
        guard distanceMeters > 1 else { return 0 }
        let moving = trainingDuration
        guard moving > 0 else { return 0 }
        return moving / (distanceMeters / 1000)
    }

    var sessionLoad: Int {
        TrainingEstimate.sessionLoad(
            duration: trainingDuration,
            averageHeartRate: resolvedAverageHeartRate,
            sport: sport
        )
    }

    /// First route point when it is a finite WGS84 coordinate.
    var startCoordinate: GeoPoint? {
        guard let first = route.first,
              first.latitude.isFinite,
              first.longitude.isFinite,
              (-90...90).contains(first.latitude),
              (-180...180).contains(first.longitude) else { return nil }
        return first
    }

    /// Steps per minute for the record card, detail grid, and stats.
    /// A cadence series is averaged over training intervals and wins over the stored mean.
    /// Health imports used to store steps divided by elapsed wall-clock time, so that scalar
    /// stays stale until a re-import. With no usable series, the stored average remains,
    /// then the mean of split cadence.
    var resolvedAverageCadence: Double {
        let trained = TrainingSeriesMath.displayAverage(stored: averageCadence, points: cadenceSeries)
        if trained > 0 { return trained }
        let fromSplits = splits.map(\.cadence).filter { $0 > 0 }
        if !fromSplits.isEmpty {
            return fromSplits.reduce(0, +) / Double(fromSplits.count)
        }
        return 0
    }

    /// Beats per minute for the detail grid, charts, and stats.
    /// Uses the same training-interval average as cadence when a heart-rate series exists.
    /// Otherwise the stored workout average.
    var resolvedAverageHeartRate: Double {
        TrainingSeriesMath.displayAverage(stored: averageHeartRate, points: heartRate)
    }

    /// Meters per step.
    /// Uses a time-weighted mean of `stride` when that series has samples.
    /// Otherwise derives stride from speed and cadence: (1000 / pace) / (cadence / 60).
    /// Pace is `averagePaceSecPerKm` (training time) and cadence is `resolvedAverageCadence`,
    /// so a corrected training-time cadence updates this derived stride.
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
        case origin, healthKitUUID, trainingDurationSeconds, conditions, startPlace
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
        trainingDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .trainingDurationSeconds) ?? 0
        conditions = try container.decodeIfPresent(WorkoutConditions.self, forKey: .conditions)
        startPlace = try container.decodeIfPresent(WorkoutStartPlace.self, forKey: .startPlace)
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
        try container.encode(trainingDurationSeconds, forKey: .trainingDurationSeconds)
        try container.encodeIfPresent(conditions, forKey: .conditions)
        try container.encodeIfPresent(startPlace, forKey: .startPlace)
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

/// A named point from a GPX file. `elevation` is the GPX `<ele>` in meters.
/// Old saves have no waypoint list and decode as an empty array.
struct RouteWaypoint: Codable, Hashable {
    var name: String
    var latitude: Double
    var longitude: Double
    var elevation: Double?
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
    /// Checkpoints parsed at import. Empty when the file has none.
    /// Routes saved before checkpoints existed also decode as empty and stay empty until the file is imported again.
    var waypoints: [RouteWaypoint]
    /// Original GPX relative to Application Support, `gpx/<id>.gpx`. Nil when this route has no stored file.
    var gpxFilename: String?

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
        creator: String = "",
        waypoints: [RouteWaypoint] = [],
        gpxFilename: String? = nil
    ) {
        self.id = id
        self.name = name
        self.points = points
        self.kind = kind
        self.importedAt = importedAt
        self.creator = creator
        self.waypoints = waypoints
        self.gpxFilename = gpxFilename
    }

    var creatorLabel: String {
        let trimmed = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, points, kind, importedAt, creator, waypoints, gpxFilename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        points = try container.decode([GeoPoint].self, forKey: .points)
        kind = try container.decode(Kind.self, forKey: .kind)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        creator = try container.decodeIfPresent(String.self, forKey: .creator) ?? ""
        waypoints = try container.decodeIfPresent([RouteWaypoint].self, forKey: .waypoints) ?? []
        gpxFilename = try container.decodeIfPresent(String.self, forKey: .gpxFilename)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(points, forKey: .points)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(importedAt, forKey: .importedAt)
        try container.encode(creator, forKey: .creator)
        try container.encode(waypoints, forKey: .waypoints)
        try container.encodeIfPresent(gpxFilename, forKey: .gpxFilename)
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

    /// Seconds used to turn a step total into steps per minute.
    /// Moving time (`HKWorkout.duration`, stored as `trainingDurationSeconds`) is the divisor.
    /// Elapsed wall-clock time is only the fallback when moving time was not recorded.
    static func trainingDuration(moving: TimeInterval, elapsed: TimeInterval) -> TimeInterval {
        if moving.isFinite, moving > 0 { return moving }
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return elapsed
    }
}

/// Training-interval means for heart rate and cadence.
/// Samples are time-weighted while the athlete is moving. A gap longer than
/// `pauseGapSeconds` is a pause (the same cutoff the detail zone shares use)
/// and is left out, so it does not dilute the mean the way elapsed time does.
enum TrainingSeriesMath {
    static let pauseGapSeconds = 30.0

    /// Trapezoid over consecutive samples at most `pauseGapSeconds` apart.
    /// Samples separated only by a pause are averaged as observations, not stretched across the gap.
    /// Nil when the series has no positive finite sample.
    static func trainingAverage(_ points: [SeriesPoint]) -> Double? {
        let samples = positiveUnique(points)
        guard !samples.isEmpty else { return nil }
        var area = 0.0
        var span = 0.0
        if samples.count >= 2 {
            for index in 1..<samples.count {
                let dt = samples[index].second - samples[index - 1].second
                guard dt > 0, dt <= pauseGapSeconds else { continue }
                area += (samples[index].value + samples[index - 1].value) / 2 * dt
                span += dt
            }
        }
        if span > 0 { return area / span }
        return samples.reduce(0) { $0 + $1.value } / Double(samples.count)
    }

    /// Series training average when it exists. Otherwise a positive stored mean.
    static func displayAverage(stored: Double, points: [SeriesPoint]) -> Double {
        if let trained = trainingAverage(points), trained > 0 { return trained }
        guard stored.isFinite, stored > 0 else { return 0 }
        return stored
    }

    private static func positiveUnique(_ points: [SeriesPoint]) -> [SeriesPoint] {
        var result: [SeriesPoint] = []
        for point in points.sorted(by: { $0.second < $1.second }) {
            guard point.second.isFinite, point.value.isFinite, point.value > 0 else { continue }
            if let previous = result.last {
                if point.second < previous.second { continue }
                if point.second == previous.second {
                    result[result.count - 1] = point
                    continue
                }
            }
            result.append(point)
        }
        return result
    }
}

enum WorkoutImport {
    /// Appends new Health workouts and fills cadence or series an earlier import left empty.
    /// A later import that only has empty series does not clear a richer row.
    /// When this row has no cadence series, a positive imported cadence replaces the stored one,
    /// so a re-import can correct steps that were divided by elapsed time.
    /// A row that already has a series keeps its scalar; the open detail page averages the series.
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
        if merged.cadenceSeries.isEmpty, imported.averageCadence > 0 {
            merged.averageCadence = imported.averageCadence
        }
        let elapsed = max(merged.elapsedDuration, 0)
        if merged.trainingDurationSeconds <= 0,
           imported.trainingDurationSeconds > 0,
           imported.trainingDurationSeconds <= elapsed {
            merged.trainingDurationSeconds = imported.trainingDurationSeconds
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
