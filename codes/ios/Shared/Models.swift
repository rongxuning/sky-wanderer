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
    /// List-card line already chosen for this workout.
    /// Missing, or blank, in phone files saved before lines were stored: the row is still unassigned.
    var motivationLine: String? = nil

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
        case distanceProgress, pauseIntervals, lapMarks, motivationLine
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
        if let raw = try container.decodeIfPresent(String.self, forKey: .motivationLine) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            motivationLine = trimmed.isEmpty ? nil : trimmed
        } else {
            motivationLine = nil
        }
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
        try container.encodeIfPresent(motivationLine, forKey: .motivationLine)
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

/// Optional replacements for the numbers and labels on the route detail card.
/// A missing field means “use the track-computed value”.
/// Segment and cumulative numbers are independent: saving one does not change the other.
/// Clearing a field removes only that override. Nothing here is written back to the GPX file.
struct RouteFactOverrides: Codable, Hashable {
    var totals: RouteTotalOverrides?
    var waypoints: [RouteWaypointFactOverride]

    init(totals: RouteTotalOverrides? = nil, waypoints: [RouteWaypointFactOverride] = []) {
        self.totals = totals
        self.waypoints = waypoints
    }

    var isEmpty: Bool {
        (totals == nil || totals?.isEmpty == true) && waypoints.allSatisfy(\.isEmpty)
    }

    private enum CodingKeys: String, CodingKey {
        case totals, waypoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totals = try container.decodeIfPresent(RouteTotalOverrides.self, forKey: .totals)
        waypoints = try container.decodeIfPresent([RouteWaypointFactOverride].self, forKey: .waypoints) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(totals, forKey: .totals)
        try container.encode(waypoints, forKey: .waypoints)
    }
}

struct RouteTotalOverrides: Codable, Hashable {
    var distanceMeters: Double? = nil
    var ascentMeters: Double? = nil
    var descentMeters: Double? = nil
    var maxElevationMeters: Double? = nil

    var isEmpty: Bool {
        distanceMeters == nil && ascentMeters == nil && descentMeters == nil && maxElevationMeters == nil
    }
}

/// One real waypoint's edited card. `sourceName` is the computed name, used to tell two
/// points at the same place apart. The GPX name on `RouteWaypoint` stays as imported.
struct RouteWaypointFactOverride: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var sourceName: String
    var name: String? = nil
    var cutoff: String? = nil
    var segmentDistanceMeters: Double? = nil
    var segmentAscentMeters: Double? = nil
    var segmentDescentMeters: Double? = nil
    var cumulativeDistanceMeters: Double? = nil
    var cumulativeAscentMeters: Double? = nil
    var cumulativeDescentMeters: Double? = nil

    var isEmpty: Bool {
        name == nil && cutoff == nil
            && segmentDistanceMeters == nil && segmentAscentMeters == nil && segmentDescentMeters == nil
            && cumulativeDistanceMeters == nil && cumulativeAscentMeters == nil && cumulativeDescentMeters == nil
    }
}

/// A named point from a GPX file. `elevation` is the GPX `<ele>` in meters.
/// `cutoff` is the 关门时间 read from the point's comment or description. Nil when the file has none.
/// Old saves have no waypoint list and decode as an empty array.
/// A waypoint saved before cutoff existed decodes with `cutoff == nil`.
struct RouteWaypoint: Codable, Hashable {
    var name: String
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    var cutoff: String? = nil
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
    /// True after the stored GPX has been read for 关门时间.
    /// Older saves decode as false, so the next launch can fill `RouteWaypoint.cutoff` without a new import.
    var cutoffResolved: Bool
    /// Card edits. Nil on routes saved before the detail card could be edited.
    var factOverrides: RouteFactOverrides?

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
        gpxFilename: String? = nil,
        cutoffResolved: Bool = false,
        factOverrides: RouteFactOverrides? = nil
    ) {
        self.id = id
        self.name = name
        self.points = points
        self.kind = kind
        self.importedAt = importedAt
        self.creator = creator
        self.waypoints = waypoints
        self.gpxFilename = gpxFilename
        self.cutoffResolved = cutoffResolved
        self.factOverrides = factOverrides
    }

    var creatorLabel: String {
        let trimmed = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, points, kind, importedAt, creator, waypoints, gpxFilename, cutoffResolved, factOverrides
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
        cutoffResolved = try container.decodeIfPresent(Bool.self, forKey: .cutoffResolved) ?? false
        factOverrides = try container.decodeIfPresent(RouteFactOverrides.self, forKey: .factOverrides)
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
        try container.encode(cutoffResolved, forKey: .cutoffResolved)
        try container.encodeIfPresent(factOverrides, forKey: .factOverrides)
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
    /// Travel, in points, before a drag may choose an axis.
    /// Below this, and whenever vertical travel wins, the list scroll keeps the touch.
    static let axisThreshold: Double = 18

    static func restingOffset(base: Double, translation: Double, predicted: Double, revealed: Double) -> Double {
        guard revealed > 0 else { return 0 }
        let next = base + translation
        let projected = base + predicted
        if min(next, projected) < -revealed / 2 {
            return -revealed
        }
        return 0
    }

    /// True only when sideways travel has passed `threshold` and beats vertical travel.
    /// A tie fails closed: the list scroll keeps the gesture.
    static func claimsHorizontal(dx: Double, dy: Double, threshold: Double = axisThreshold) -> Bool {
        let horizontal = abs(dx)
        return horizontal >= threshold && horizontal > abs(dy)
    }

    /// True when vertical travel has passed `threshold` and is at least the sideways travel.
    static func yieldsToVerticalScroll(dx: Double, dy: Double, threshold: Double = axisThreshold) -> Bool {
        let vertical = abs(dy)
        return vertical >= threshold && vertical >= abs(dx)
    }

    /// Whether the delete pan may leave `.possible`. Vertical and diagonal pans return false
    /// and never claim the touch, so the list scroll keeps it.
    static func shouldBeginDeletePan(
        translationX: Double,
        translationY: Double,
        velocityX: Double,
        velocityY: Double
    ) -> Bool {
        let travel = (translationX * translationX + translationY * translationY).squareRoot()
        if travel >= 8 {
            return claimsHorizontal(dx: translationX, dy: translationY, threshold: 8)
        }
        // A fast sideways flick can be obvious before the finger has moved 8pt.
        return claimsHorizontal(dx: velocityX, dy: velocityY, threshold: 120)
    }

    /// Where the finger would be after a short deceleration. Fed to `restingOffset`.
    static func predictedTranslation(translation: Double, velocity: Double) -> Double {
        translation + velocity * 0.2
    }
}

/// Short lines for the record list. A stored line stays with that workout.
/// A new row takes one unused library line. The pick is FNV-1a over the Health id,
/// or the workout id when there is no Health id, among the lines not yet stored.
/// `Hasher` is salted per process and is not used.
enum RecordMotivation {
    static let lines: [String] = [
        "晨光只沾到半面山坡",
        "露水还挂在草叶尖上",
        "天色刚亮路就已经醒",
        "第一缕风从谷口过来",
        "阳光顺着树缝往下漏",
        "雾气贴着河面慢慢移",
        "东边的云先被照亮了",
        "影子还短人已经出门",
        "新鞋印留在湿润土上",
        "脚掌躲开松动的石头",
        "袜口进了一点点细沙",
        "脚趾还记得那块尖石",
        "泥点溅到小腿的外侧",
        "鞋带在第三孔重新系好",
        "脚热起来风就刚好",
        "落脚处选在草根旁边",
        "松枝擦过帽檐的边缘",
        "桦树皮在光里发白",
        "枯叶在脚下沙沙地响",
        "树根横出来当成台阶",
        "林荫把热气挡在外面",
        "一根藤挂在路的左侧",
        "高处的鸟巢并不受惊",
        "树脂气味一点点近了",
        "溪声比人先到达桥边",
        "跳石只有一块也够用",
        "水面反光晃到眼睛",
        "浅滩的水没过鞋边",
        "泉眼旁边的石头冰手",
        "河风比林里更直一些",
        "桥板响了一声人过去",
        "水雾沾在眉毛上边",
        "下游的弯还能看见",
        "石壁把风收成一条缝",
        "岩层的纹路横着走",
        "青苔告诉这里常年阴",
        "碎石路要看清落点",
        "圆石头踩上去容易滑",
        "崖边的土很松要靠里",
        "鞍部的风换了方向",
        "岭脊细得只容一人",
        "远处积雪还不着急",
        "坡度缓下来肩可以松",
        "上到能看见下一条沟",
        "山梁像一条安静的线",
        "拐过岩壁风突然小了",
        "这段碎石终于到头",
        "海拔是一点点挪上去",
        "回头时云已经低于脚",
        "帽檐压低只看前方三步",
        "口袋里的纸条还是干的",
        "水袋轻了步子仍在",
        "手心的盐是路留下的",
        "背包不再左右晃动",
        "肩带勒过的地方松一松",
        "手腕上的汗已经凉了",
        "呼吸比刚才更长一点",
        "心跳稳了步幅自己出来",
        "话先留到平路再讲",
        "旁边的影子不必去追",
        "这一公里交给双脚",
        "跑过树影再回到土路",
        "平地用来把气喘匀",
        "弯道之后把视线放开",
        "草地比石头更吃力",
        "晒热的石板有点烫脚",
        "阴坡里步子可以缓",
        "开阔处天显得更低",
        "分叉口选更安静的那条",
        "窄路把肩膀收进来",
        "逆风的一段低下头",
        "顺风时也不把步子拉开",
        "雨丝斜着人照直走",
        "雷在山后脚下仍是干的",
        "云影从坡上滑过去",
        "落日把最后的坡照暖",
        "黄昏的土还带着温",
        "夜色还早岭线还亮着",
        "傍晚的风比早晨软",
        "星子还没出来人已下山",
        "月色够看清路就行",
        "今天的弯比昨天熟",
        "地图上的折线变短了",
        "路条被汗浸软了边",
        "旧脚印被新土盖住",
        "石堆说明有人来过",
        "木牌的漆已经斑驳",
        "铁丝网沿着山沟走",
        "羊肠小道贴着山坡",
        "田埂跑完就接上土坡",
        "村口的狗并不追人",
        "炊烟在很远的地方",
        "桥下的脚步声会停一下",
        "里程留在鞋底纹路里",
        "这一程只和这条沟作伴",
        "远峰还是蓝的不必追",
        "下一座山先放在眼里",
        "把山顶从目光里拿开",
        "只关心脚下接下来三步",
        "远处的村子先不靠近",
        "鹰在头顶转了一圈",
        "松鼠窜过并不停留",
        "蝉声把整个午后填满",
        "草籽沾在袜筒上也无妨",
        "蒲公英擦着小腿过去",
        "蕨类挡住半条小路",
        "蘑菇长在倒木旁边",
        "野花不采只是路过",
        "蜘蛛网在晨光里发亮",
        "落叶盖住的坑绕开",
        "蚂蚁的队伍让到一边",
        "蝴蝶停在帽檐上片刻",
        "山雀换了一拨人还在",
        "风把尘土从膝前吹走",
        "云缝里漏下一块光",
        "雾走了路自己还在",
        "雨停后石面要踩实",
        "冰雹并没有下到这边",
        "潮气贴着裤腿往上",
        "干草的味道在风里",
        "泥土是软的步子就沉",
        "沙地让脚下的节奏变慢",
        "雪线还在上面人在下面",
        "霜还没化就先出发",
        "冰渣还在阴处留着",
        "开春的泥比寒天更滑",
        "夏天的林荫值得绕路",
        "秋叶把路铺成另一种颜色",
        "冬天的呼气在眼前白一下",
        "季节换了鞋还是这双",
        "同一条岭今天重新认识",
        "去年的标记还在树上",
        "新踩出来的岔路先不试",
        "熟悉的弯仍要看脚下",
        "第一次走就放慢些",
        "回头的方向留给下山",
        "上山的时候少说两句",
        "下山同样把步子放稳",
        "平路不是用来冲的",
        "陡坡用更短的步子",
        "碎石段把眼睛放低",
        "土路段可以把肩放松",
        "过桥时脚步放轻一点",
        "钻林子时低头看藤",
        "走出林子天就宽了",
        "进沟里风会小下来",
        "登到脊上风又大了",
        "下到谷底再慢慢起来",
        "沿溪走了很长一段",
        "离开水声之后更静",
        "绕开塌方的那一角",
        "跨过倒在路上的树",
        "扶一下岩石再继续",
        "手杖点在稳的地方",
        "没带杖就双手帮忙平衡",
        "休息只是站着喝水",
        "歇半步并不是停住",
        "站定看一眼然后再迈",
        "坐下的石头还是温的",
        "站起来时腿并不沉",
        "补给放在能看见的侧袋",
        "帽子摘下来扇了两下",
        "袖口卷到不挡手腕",
        "拉链拉开一点来散热",
        "头巾吸走额上的汗",
        "眼镜起雾就拿下来",
        "耳机里什么都不放",
        "只听自己的脚步和风",
        "数呼吸比数公里轻松",
        "先不看还剩下多少路",
        "这一段的名字叫慢慢",
        "跑的时候也像在走",
        "走的时候心并不赶",
        "徒步把下午拉得很长",
        "跑步只穿过这片开阔",
        "两种走法都算在路上",
        "今天用跑把平地吃掉",
        "坡上改成走肩就松了",
        "走跑交替肩更轻松",
        "步频跟着胸口的起伏",
        "快慢交给脚下的土路",
        "别人的脚步在另一条沟",
        "自己的步子自己最熟",
        "四下无人也能听清风",
        "独自一人山就更大",
        "结伴时把话留短些",
        "前后错开一小段距离",
        "等同伴时抬头看云",
        "被等的那个人也不急",
        "会合点是那棵歪脖子树",
        "分开走最后还是同路",
        "孩子的步子更碎也更欢",
        "老人的杖点得很稳",
        "谁快谁慢都不叫一声",
        "让出路给下山的人",
        "碰面点个头就过去",
        "狗在前面轻轻探路",
        "人在后面跟着脚印",
        "背包重一点路仍认人",
        "轻装的时候更要低头",
        "相机仍留在袋子里",
        "风景留在行进里看",
        "拍照的弯先放过去",
        "记下的是脚的感觉",
        "回来再讲给别人听",
        "眼下只把这块路走实",
        "看看影子就知道早晚",
        "时间落在影子的长度上",
        "正午的影缩成一小团",
        "下午的光变斜之后更软",
        "早晨的冷留在袖口",
        "中午的热留在帽檐",
        "一天就这样被路切开",
        "每过一个垭口天就不同",
        "同一座山上下两重天",
        "阴坡和阳坡差一件衣服",
        "风口处把帽子按住",
        "背风的凹地可以喘匀",
        "暴露的脊线低下身子",
        "树木突然变矮就快到顶",
        "草甸开了就知道高了",
        "石海要一个一个踩",
        "流石坡上不停留太久",
        "碎屑在脚下轻轻滑",
        "大块岩石拿来借力",
        "岩缝里先不要伸手",
        "稳的平面才放整只脚",
        "先用脚掌试探再踩实",
        "后脚抬起时不带碎石",
        "拐过碎石膝盖仍轻松",
        "走过草甸步子自然打开",
        "手臂掠过身边的草尖",
        "肩线在风里保持平着",
        "目光只落在近处的路",
        "嘴里的气在冷风里白",
        "舌头顶着上颚并不渴",
        "口水还够就先不喝",
        "到泉边再小口补上",
        "清水要留给后半程",
        "食物撕开一条小口",
        "带咸味的更好吃一些",
        "甜的留到腿软的时候",
        "吃完擦擦手再往前",
        "垃圾塞回自己的口袋",
        "果皮也不留在石头上",
        "路还是来时的样子",
        "人过了草会慢慢弹起",
        "尘土落下就是没人了",
        "风把泥上的痕迹吹淡",
        "雨会把地上的鞋印收走",
        "明天的人看见的是新土",
        "走路的人只管这个弯",
        "腿上的累来自刚才的坡",
        "明天的坡还没到脚下",
        "此刻的风正在耳边",
        "这一步是热的下一步还不知道",
        "脚知道的比眼睛多",
        "眼睛负责三步之内",
        "耳朵负责后面有没有人",
        "鼻子负责松脂和土",
        "皮肤负责风的方向",
        "全部感官都在这条路上",
        "每块石头都有自己的位置",
        "山把人收成一个小点",
        "人把山走成一条线",
        "这条线还没走到头",
        "土沾在鞋边就算记下",
        "画到林子边上歇口气",
        "再从亮处一步步回去",
        "回家的路也是山的一部分",
        "门口的石阶算最后一级",
        "鞋脱下来土还沾着",
        "袜子上的草籽抖一抖",
        "水杯空了肩却松了",
        "两条腿沉得刚刚好",
        "明天还想再走一条",
        "今晚先把这条记住",
        "梦里如果还有坡也不奇怪",
        "醒来时窗外并没有雾",
        "山在别处人在屋里",
        "屋里仍能听见自己的呼吸",
        "那口气是路上带回来的",
        "肩上的红印慢慢会褪",
        "脚上的热要到夜里才散",
        "窗边的鞋还朝外放着",
        "下次出门它还认得路",
        "这条路也认得这双鞋",
        "如此来回并不喧哗",
        "山野就喜欢这种来回",
        "人不多话路就显得长",
        "话少的时候景更清楚",
        "看清楚脚下就够了",
        "多说的话也会被风带走",
        "被山风卷走的只是热汗",
        "留下的是还在移动的鞋",
        "人还在岭上风也在",
        "脚还抬得起来就往前",
        "放脚的声音轻得刚好",
        "轻到只有自己听见",
        "听见脚步就明白没停",
        "不停就能遇上前面的光",
        "光在树和树的中间",
        "中间刚好够一个人过",
        "独自穿过时林子很静",
        "快慢之外人还在路上",
        "人在就因为脚还踩土",
        "土是凉的心是稳的",
        "稳的步子能走很远的弯",
        "弯多也不换成直线",
        "直线不属于这座山",
        "山要的是顺着它的人",
        "顺着它风也会帮忙",
        "帮忙的方式是推一下背",
        "背后的风只轻轻一推",
        "这里用不着逞快的步子",
        "用得上的是还能迈的腿",
        "腿还热路就还没有结束",
        "路还长着就先不看表",
        "表上的数字不如石头真实",
        "那块石头就挡在前面",
        "前面还有一小段平的",
        "平的地方把气接上",
        "接上之后再遇坡也不慌",
        "从容着走会省一点力",
        "更远的岭先不去想",
        "目标小到只剩下一块石头",
        "过完这块就换下一块",
        "一块一块天就暗了",
        "暗了就把头灯留到真正需要",
        "需要之前天光还够用",
        "够用的光里把路走完这一截",
        "这一截有个小小的水洼",
        "小水洼照出一段云",
        "云走得慢人也不催它",
        "不催的步伐最像这条路",
        "这步伐和山路很合",
    ]

    private static let lineSet = Set(lines)
    private static let overflowScenes = [
        "山径上", "林路边", "石阶旁", "溪岸边", "岭脊上", "谷道里",
        "松荫下", "风口处", "土路间", "云阶旁", "竹影里", "崖边路",
    ]
    private static let overflowPaces = ["慢慢", "从容", "稳步", "轻轻", "安静", "照常"]
    private static let overflowTails = ["再走", "续行", "前行", "走着"]

    /// Blank text counts as unassigned, including values saved as spaces.
    static func storedLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Health id when the row has one; otherwise the stored workout id.
    /// `avoiding` is the set of lines already stored on other rows.
    static func line(for workoutID: UUID, healthKitUUID: String? = nil, avoiding used: Set<String> = []) -> String {
        let key = WorkoutDenylist.healthIdentity(healthKitUUID) ?? workoutID.uuidString
        return claim(key: key, used: used)
    }

    /// FNV-1a over the UTF-8 key, folded into the full library. Stable across launches.
    static func index(for key: String) -> Int {
        guard !lines.isEmpty else { return 0 }
        return Int(fnv(key) % UInt64(lines.count))
    }

    /// Fills rows that do not yet have a line. Rows that already have one are left as stored.
    /// Pending rows are ordered by Health id, then workout id, so a new row cannot move the others.
    static func assignMissing(_ workouts: inout [WorkoutRecord]) {
        var used = Set<String>()
        for workout in workouts {
            if let line = storedLine(workout.motivationLine) {
                used.insert(line)
            }
        }
        let pending = workouts.indices.filter { storedLine(workouts[$0].motivationLine) == nil }
            .sorted { left, right in
                let leftKey = identityKey(workouts[left])
                let rightKey = identityKey(workouts[right])
                if leftKey != rightKey { return leftKey < rightKey }
                return workouts[left].id.uuidString < workouts[right].id.uuidString
            }
        for index in pending {
            let line = claim(key: identityKey(workouts[index]), used: used)
            workouts[index].motivationLine = line
            used.insert(line)
        }
    }

    private static func identityKey(_ workout: WorkoutRecord) -> String {
        WorkoutDenylist.healthIdentity(workout.healthKitUUID) ?? workout.id.uuidString
    }

    private static func claim(key: String, used: Set<String>) -> String {
        let remaining = lines.filter { !used.contains($0) }
        if !remaining.isEmpty {
            return remaining[Int(fnv(key) % UInt64(remaining.count))]
        }
        let span = overflowScenes.count * overflowPaces.count * overflowTails.count
        let hash = fnv(key)
        let limit = span * 32 + used.count + 8
        var probe = 0
        while probe < limit {
            let slot = Int((hash &+ UInt64(probe)) % UInt64(span))
            let round = probe / span
            let candidate = overflowLine(slot: slot, round: round)
            if candidate.count <= 16, !used.contains(candidate), !lineSet.contains(candidate) {
                return candidate
            }
            probe += 1
        }
        var n = 0
        while true {
            let candidate = "续\(n)"
            if candidate.count <= 16, !used.contains(candidate), !lineSet.contains(candidate) {
                return candidate
            }
            n += 1
        }
    }

    /// Fixed scene, pace, and ending. A later round appends a count so the line stays unique.
    private static func overflowLine(slot: Int, round: Int) -> String {
        let sceneCount = overflowScenes.count
        let paceCount = overflowPaces.count
        let scene = overflowScenes[slot % sceneCount]
        let pace = overflowPaces[(slot / sceneCount) % paceCount]
        let tail = overflowTails[(slot / (sceneCount * paceCount)) % overflowTails.count]
        let base = scene + pace + "地" + tail
        if round <= 0 { return base }
        return base + String(round + 1)
    }

    private static func fnv(_ key: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

/// Even samples of a route for the list track.
/// The first and last points stay put so the line still starts and finishes on the real track.
enum RecordTrackPath {
    static func simplified(_ points: [GeoPoint], limit: Int = 180) -> [GeoPoint] {
        guard limit >= 2, points.count > limit else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            let position = min(points.count - 1, Int((Double(index) * step).rounded()))
            return points[position]
        }
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
    /// A stored list-card line stays on the existing row. A newly appended row gets one unused line.
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
        RecordMotivation.assignMissing(&workouts)
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
        if RecordMotivation.storedLine(merged.motivationLine) == nil {
            merged.motivationLine = RecordMotivation.storedLine(imported.motivationLine)
        }
        return merged
    }

    private static func fill<T>(_ existing: inout [T], _ incoming: [T]) {
        if existing.isEmpty, !incoming.isEmpty {
            existing = incoming
        }
    }
}
