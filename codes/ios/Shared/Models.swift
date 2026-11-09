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

/// One pause or auto-pause, in seconds after the workout start.
/// `endSecond` is the resume. Overlapping marks from manual and motion pause are merged.
struct WorkoutPause: Codable, Hashable {
    var startSecond: Double
    var endSecond: Double

    /// A HealthKit pause or resume mark before it is paired into an interval.
    /// `duration` covers the whole pause when the event itself has a length.
    /// A duration under one second is only the instant the pause began.
    struct Mark: Equatable {
        var second: Double
        var isResume: Bool
        var duration: Double
    }

    static func intervals(from marks: [Mark], elapsed: TimeInterval) -> [WorkoutPause] {
        let span = elapsed.isFinite && elapsed > 0 ? elapsed : 0
        let sorted = marks.filter { $0.second.isFinite && $0.duration.isFinite }.sorted { lhs, rhs in
            if lhs.second == rhs.second { return !lhs.isResume && rhs.isResume }
            return lhs.second < rhs.second
        }
        var raw: [WorkoutPause] = []
        var open: Double?
        var depth = 0
        for mark in sorted {
            let second = clamp(mark.second, span: span)
            if mark.isResume {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start = open {
                    raw.append(WorkoutPause(startSecond: start, endSecond: max(start, second)))
                    open = nil
                }
                continue
            }
            if mark.duration >= 1 {
                let end = clamp(second + mark.duration, span: span)
                raw.append(WorkoutPause(startSecond: second, endSecond: max(second, end)))
                continue
            }
            if depth == 0 { open = second }
            depth += 1
        }
        if let start = open, span > start {
            raw.append(WorkoutPause(startSecond: start, endSecond: span))
        }
        return merged(raw)
    }

    static func merged(_ pauses: [WorkoutPause]) -> [WorkoutPause] {
        let ordered = pauses
            .filter { $0.startSecond.isFinite && $0.endSecond.isFinite && $0.endSecond > $0.startSecond }
            .sorted { $0.startSecond < $1.startSecond }
        var result: [WorkoutPause] = []
        for pause in ordered {
            if var last = result.last, pause.startSecond <= last.endSecond {
                last.endSecond = max(last.endSecond, pause.endSecond)
                result[result.count - 1] = last
            } else {
                result.append(pause)
            }
        }
        return result
    }

    /// Seconds of these pauses that fall inside `[start, end)`.
    static func overlap(_ pauses: [WorkoutPause], from start: Double, to end: Double) -> Double {
        guard end > start else { return 0 }
        return pauses.reduce(0) { partial, pause in
            let lower = max(start, pause.startSecond)
            let upper = min(end, pause.endSecond)
            return partial + max(0, upper - lower)
        }
    }

    private static func clamp(_ second: Double, span: TimeInterval) -> Double {
        let lower = max(0, second)
        guard span > 0 else { return lower }
        return min(lower, span)
    }
}

/// One HealthKit lap or segment, in seconds after the workout start.
/// `second` is when the lap ended. `distanceMeters` is the recorded lap length,
/// or `0` when the event did not say how far that lap was.
struct WorkoutLapMark: Codable, Hashable {
    var second: Double
    var distanceMeters: Double
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
    /// Meters in this row. `0` on splits saved before leftover distance was stored.
    /// A full kilometer is 1000. A short last kilometer is the real remainder.
    var distanceMeters: Double
    /// Moving seconds in this row. `0` on splits saved before duration was stored.
    /// For a full kilometer this is the same number as `paceSecPerKm`.
    var durationSeconds: Double

    var id: Int { index }

    init(
        index: Int,
        paceSecPerKm: Double,
        cadence: Double,
        heartRate: Double,
        partial: Bool,
        energyKilocalories: Double = 0,
        distanceMeters: Double = 0,
        durationSeconds: Double = 0
    ) {
        self.index = index
        self.paceSecPerKm = paceSecPerKm
        self.cadence = cadence
        self.heartRate = heartRate
        self.partial = partial
        self.energyKilocalories = energyKilocalories
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case index, paceSecPerKm, cadence, heartRate, partial, energyKilocalories
        case distanceMeters, durationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        paceSecPerKm = try container.decode(Double.self, forKey: .paceSecPerKm)
        cadence = try container.decode(Double.self, forKey: .cadence)
        heartRate = try container.decode(Double.self, forKey: .heartRate)
        partial = try container.decode(Bool.self, forKey: .partial)
        energyKilocalories = try container.decodeIfPresent(Double.self, forKey: .energyKilocalories) ?? 0
        distanceMeters = try container.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 0
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(paceSecPerKm, forKey: .paceSecPerKm)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(heartRate, forKey: .heartRate)
        try container.encode(partial, forKey: .partial)
        try container.encode(energyKilocalories, forKey: .energyKilocalories)
        try container.encode(distanceMeters, forKey: .distanceMeters)
        try container.encode(durationSeconds, forKey: .durationSeconds)
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
    /// Cumulative official distance, meters at wall-clock seconds after `start`.
    /// Empty when this file was saved before the series existed, or when HealthKit's
    /// distance samples did not match the official total. Kilometer rows are cut on
    /// this curve so a GPS trace cannot slide the boundaries.
    var distanceProgress: [SeriesPoint] = []
    /// Recorded pause and auto-pause intervals, in seconds after `start`.
    /// Empty when the workout was not paused, or when pauses were not stored yet.
    var pauseIntervals: [WorkoutPause] = []
    /// Lap or segment marks. Empty when this file was saved before laps were stored,
    /// or when the workout had none. Equal 1 km laps override the distance curve.
    var lapMarks: [WorkoutLapMark] = []

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

    /// Steps per minute for the record card, detail grid, splits footer, and stats.
    /// This is total steps ÷ training minutes, stored as `averageCadence` when import
    /// kept the step-count quotient. The cadence series is the chart: its time-weighted
    /// mean drops gaps longer than 30 seconds and pulls toward the sampled sections,
    /// so it is not this headline. When the saved scalar is that series mean (an older
    /// import overwrote the step quotient), the steps are rebuilt from the series and
    /// divided by training minutes. With no step total, the mean of split cadence remains.
    var resolvedAverageCadence: Double {
        let stored = averageCadence.isFinite && averageCadence > 0 ? averageCadence : 0
        if let seriesMean = TrainingSeriesMath.trainingAverage(cadenceSeries), seriesMean > 0 {
            let independent = stored > 0 && abs(stored - seriesMean) > max(1, seriesMean * 0.02)
            if independent { return stored }
            // The saved scalar is the series mean. Rebuild steps ÷ training minutes, and
            // only use it when gaps pull that total down. A higher result would be the
            // series stretched across a shorter training window, which is not a step total.
            if let rebuilt = TrainingSeriesMath.stepsPerTrainingMinute(
                cadenceSeries,
                trainingSeconds: trainingDurationSeconds,
                elapsedSeconds: elapsedDuration
            ), rebuilt > 0, stored <= 0 || rebuilt <= stored + 0.5 {
                return rebuilt
            }
        }
        if stored > 0 { return stored }
        let fromSplits = splits.map(\.cadence).filter { $0 > 0 }
        if !fromSplits.isEmpty {
            return fromSplits.reduce(0, +) / Double(fromSplits.count)
        }
        return 0
    }

    /// Beats per minute for the detail grid, charts, and stats.
    /// Uses the training-interval series when heart-rate samples exist.
    /// Otherwise the stored workout average.
    var resolvedAverageHeartRate: Double {
        TrainingSeriesMath.displayAverage(stored: averageHeartRate, points: heartRate)
    }

    /// Meters per step for the same headlines as cadence.
    /// Total steps = `resolvedAverageCadence` × training minutes, and stride = distance ÷ those steps.
    /// That is the same identity as speed ÷ (cadence / 60), so stride × (cadence / 60) matches
    /// 1000 / average pace. The stride series stays on the chart; Watch often records
    /// `runningStrideLength` only while the workout is classified as running.
    /// Returns 0 when the step total is missing, or the result is outside 0.30–2.20 m.
    var averageStrideMeters: Double {
        let cadence = resolvedAverageCadence
        let moving = trainingDuration
        guard cadence > 30, moving > 0, distanceMeters > 1 else { return 0 }
        let steps = cadence * (moving / 60)
        guard steps > 0 else { return 0 }
        let measured = distanceMeters / steps
        guard measured.isFinite, measured >= 0.30, measured <= 2.20 else { return 0 }
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
        case distanceProgress, pauseIntervals, lapMarks
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
        distanceProgress = try container.decodeIfPresent([SeriesPoint].self, forKey: .distanceProgress) ?? []
        pauseIntervals = try container.decodeIfPresent([WorkoutPause].self, forKey: .pauseIntervals) ?? []
        lapMarks = try container.decodeIfPresent([WorkoutLapMark].self, forKey: .lapMarks) ?? []
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
        try container.encode(distanceProgress, forKey: .distanceProgress)
        try container.encode(pauseIntervals, forKey: .pauseIntervals)
        try container.encode(lapMarks, forKey: .lapMarks)
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
    /// Heart rate still uses this. Headline cadence does not: that number is total steps
    /// divided by training minutes.
    static func displayAverage(stored: Double, points: [SeriesPoint]) -> Double {
        if let trained = trainingAverage(points), trained > 0 { return trained }
        guard stored.isFinite, stored > 0 else { return 0 }
        return stored
    }

    /// Time-weighted mean that keeps long gaps. The stride chart uses this so its
    /// average still describes the plotted series, not the headline stride.
    static func spanAverage(_ points: [SeriesPoint]) -> Double? {
        let samples = positiveUnique(points)
        guard !samples.isEmpty else { return nil }
        if samples.count >= 2 {
            var area = 0.0
            var span = 0.0
            for index in 1..<samples.count {
                let dt = samples[index].second - samples[index - 1].second
                guard dt > 0 else { continue }
                area += (samples[index].value + samples[index - 1].value) / 2 * dt
                span += dt
            }
            if span > 0 { return area / span }
        }
        return samples.reduce(0) { $0 + $1.value } / Double(samples.count)
    }

    /// Steps implied by the cadence series, divided by stored training minutes.
    /// Gaps longer than a pause add no steps. Returns nil when training time was not
    /// stored, or the samples cover less than half of that time.
    static func stepsPerTrainingMinute(
        _ points: [SeriesPoint],
        trainingSeconds: TimeInterval,
        elapsedSeconds: TimeInterval
    ) -> Double? {
        guard trainingSeconds.isFinite, trainingSeconds > 0,
              elapsedSeconds.isFinite, trainingSeconds <= elapsedSeconds else { return nil }
        let samples = positiveUnique(points)
        guard samples.count >= 2 else { return nil }
        var steps = 0.0
        var covered = 0.0
        for index in 1..<samples.count {
            let dt = samples[index].second - samples[index - 1].second
            guard dt > 0, dt <= pauseGapSeconds else { continue }
            steps += (samples[index].value + samples[index - 1].value) / 2 / 60 * dt
            covered += dt
        }
        guard covered >= trainingSeconds * 0.5, steps > 0 else { return nil }
        return steps / (trainingSeconds / 60)
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

/// Ids that must not come back from Apple Health or `Database.insertWorkout`.
/// Remembering an id does not delete the workout from HealthKit.
struct WorkoutDenylist: Codable, Hashable {
    var healthKitUUIDs: [String] = []
    var localWorkoutIDs: [UUID] = []

    private enum CodingKeys: String, CodingKey {
        case healthKitUUIDs
        case localWorkoutIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        healthKitUUIDs = try container.decodeIfPresent([String].self, forKey: .healthKitUUIDs) ?? []
        localWorkoutIDs = try container.decodeIfPresent([UUID].self, forKey: .localWorkoutIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(healthKitUUIDs, forKey: .healthKitUUIDs)
        try container.encode(localWorkoutIDs, forKey: .localWorkoutIDs)
    }

    /// A non-empty Health id is the identity. Blank ids are device-only.
    static func healthIdentity(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    mutating func remember(_ workout: WorkoutRecord) {
        if let healthID = Self.healthIdentity(workout.healthKitUUID) {
            if !healthKitUUIDs.contains(healthID) {
                healthKitUUIDs.append(healthID)
            }
        } else if !localWorkoutIDs.contains(workout.id) {
            localWorkoutIDs.append(workout.id)
        }
    }

    func blocks(_ workout: WorkoutRecord) -> Bool {
        if let healthID = Self.healthIdentity(workout.healthKitUUID) {
            return healthKitUUIDs.contains(healthID)
        }
        return localWorkoutIDs.contains(workout.id)
    }

    func containsHealthKitUUID(_ raw: String?) -> Bool {
        guard let healthID = Self.healthIdentity(raw) else { return false }
        return healthKitUUIDs.contains(healthID)
    }
}

/// Resting card offset after a horizontal drag. `0` is closed.
/// A negative value only means the delete button is visible. Callers must not delete from it.
enum RecordCardSwipe {
    static func restingOffset(base: Double, translation: Double, predicted: Double, revealed: Double) -> Double {
        guard revealed > 0 else { return 0 }
        let next = base + translation
        let projected = base + predicted
        if min(next, projected) < -revealed / 2 {
            return -revealed
        }
        return 0
    }
}

enum WorkoutImport {
    /// Appends new Health workouts and fills cadence or series an earlier import left empty.
    /// A later import that only has empty series does not clear a richer row.
    /// When this row has no cadence series, a positive imported cadence replaces the stored one,
    /// so a re-import can correct steps that were divided by elapsed time.
    /// A row that already has a series keeps its scalar. The detail page reads that step total;
    /// it does not replace the scalar with a series average. Splits stay as stored here.
    /// Display rebuilds them from equal 1 km lap marks when a later import stored those,
    /// otherwise from `distanceProgress`, and from the route when that curve is still missing.
    /// Drops bundled sample workouts, including the fixed sample ids, so the list keeps real sessions.
    /// `denylist` keeps user-deleted Health workouts from being appended or refreshed.
    static func merge(
        _ imported: [WorkoutRecord],
        into workouts: inout [WorkoutRecord],
        skipping denylist: WorkoutDenylist = WorkoutDenylist()
    ) {
        for record in imported {
            guard let healthID = record.healthKitUUID else { continue }
            if denylist.containsHealthKitUUID(healthID) { continue }
            if let index = workouts.firstIndex(where: { $0.healthKitUUID == healthID }) {
                workouts[index] = merging(workouts[index], with: record)
                continue
            }
            workouts.append(record)
        }
        workouts.removeAll { SampleLibrary.isSeededWorkout($0) || denylist.blocks($0) }
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
        fill(&merged.distanceProgress, imported.distanceProgress)
        fill(&merged.pauseIntervals, imported.pauseIntervals)
        fill(&merged.lapMarks, imported.lapMarks)
        return merged
    }

    private static func fill<T>(_ existing: inout [T], _ incoming: [T]) {
        if existing.isEmpty, !incoming.isEmpty {
            existing = incoming
        }
    }
}
