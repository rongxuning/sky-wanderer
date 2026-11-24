import CoreLocation
import Foundation
import HealthKit

/// Brand extension point. Phase 1 only builds `AppleActivitySource`.
/// A later brand implements this and is constructed beside Apple — the views
/// read workouts, they do not talk to HealthKit directly.
protocol ActivitySource {
    var brandName: String { get }
    func prepare() async throws
    /// Apple Health workouts mapped onto `SportKind`. See `AppleHealth.importWorkouts`.
    func importWorkouts(known: Set<String>, denied: WorkoutDenylist) async throws -> [WorkoutRecord]
}

struct AppleActivitySource: ActivitySource {
    var brandName: String { "Apple" }

    func prepare() async throws {
        try await AppleHealth.authorize()
    }

    func importWorkouts(known: Set<String>, denied: WorkoutDenylist) async throws -> [WorkoutRecord] {
        try await AppleHealth.importWorkouts(known: known, denied: denied)
    }
}

struct DayHealth: Equatable {
    var heartRate: Double?
    var sleepHours: Double?
    var steps: Int?
}

enum RecorderError: Error {
    case unavailable
    case failed
}

enum AppleHealth {
    static let store = HKHealthStore()
    static var available: Bool { HKHealthStore.isHealthDataAvailable() }
    private static let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())

    static func authorize() async throws {
        guard available else { throw RecorderError.unavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    /// Share status for workouts. HealthKit does not tell the app whether reads were allowed.
    static func workoutShareAuthorization() -> MeTrainingShareState {
        guard available else { return .unavailable }
        switch store.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized:
            return .authorized
        case .sharingDenied:
            return .denied
        default:
            return .notDetermined
        }
    }

    /// Newest workouts already stored are rebuilt so a re-import can fill missing series.
    static let refreshWindow = 20
    /// New workouts built per pass. A caller with more history runs another pass.
    static let newBatchSize = 100

    /// Lists every Apple Health workout, then builds full records only for the newest
    /// `refreshWindow` stored ones and up to `newBatchSize` that are not stored yet.
    /// Deleted workouts are skipped. Activity types outside the app list become `other`.
    /// A pass that returns `newBatchSize` unknown ids may have more history left.
    static func importWorkouts(
        known: Set<String>,
        denied: WorkoutDenylist
    ) async throws -> [WorkoutRecord] {
        guard available else { return [] }
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: nil,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    hop(Result<[HKWorkout], Error>.failure(error), to: continuation)
                    return
                }
                hop(Result.success((samples as? [HKWorkout]) ?? []), to: continuation)
            }
            execute(query)
        }
        var records: [WorkoutRecord] = []
        var refreshed = 0
        var added = 0
        for workout in workouts {
            let id = workout.uuid.uuidString
            if denied.containsHealthKitUUID(id) { continue }
            if known.contains(id) {
                guard refreshed < refreshWindow else { continue }
                refreshed += 1
            } else {
                guard added < newBatchSize else { continue }
                added += 1
            }
            records.append(await record(from: workout, sport: SportKind.from(workout)))
        }
        return records
    }

    static func today() async -> DayHealth {
        guard available else { return DayHealth(heartRate: nil, sleepHours: nil, steps: nil) }
        async let heart = latestHeartRate()
        async let sleep = sleepHours()
        async let steps = stepCountToday()
        return await DayHealth(heartRate: heart, sleepHours: sleep, steps: steps)
    }

    /// Steps per minute from the workout's step count, divided by moving time.
    /// `HKWorkout.duration` excludes pauses and is the same value stored as `trainingDurationSeconds`.
    /// Elapsed wall-clock time is only the fallback when that duration was not recorded.
    /// A time-range step query is only the fallback when the workout did not store that statistic.
    /// watchOS 26.5 has no `HKQuantityTypeIdentifier.runningCadence` member, and Apple does not
    /// document that identifier, so both targets use step count.
    private static func cadenceStepsPerMinute(for workout: HKWorkout) async -> Double {
        let duration = CadenceMath.trainingDuration(
            moving: workout.duration,
            elapsed: workout.endDate.timeIntervalSince(workout.startDate)
        )
        if let steps = sum(workout, identifier: .stepCount, unit: .count()) {
            let normalized = CadenceMath.stepsPerMinute(steps: steps, duration: duration)
            if normalized > 0 { return normalized }
        }
        if let steps = await quantitySum(.stepCount, unit: .count(), start: workout.startDate, end: workout.endDate) {
            return CadenceMath.stepsPerMinute(steps: steps, duration: duration)
        }
        return 0
    }

    private static func quantitySum(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                hop(stats?.sumQuantity()?.doubleValue(for: unit), to: continuation)
            }
            execute(query)
        }
    }

    private static func record(from workout: HKWorkout, sport: SportKind) async -> WorkoutRecord {
        // Prefer statistics. Some imported workouts leave statistics(for:) nil and only
        // fill the older totals, which would otherwise be stored as 0.
        // Heart rate has no workout-level total, so it stays on statistics.
        let distance = sum(workout, identifier: .distanceWalkingRunning, unit: .meter())
            ?? workout.totalDistance?.doubleValue(for: .meter())
            ?? 0
        let energy = sum(workout, identifier: .activeEnergyBurned, unit: .kilocalorie())
            ?? workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            ?? 0
        let heart = average(workout, identifier: .heartRate, unit: beatsPerMinute) ?? 0
        var climb = 0.0
        if let quantity = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
            climb = quantity.doubleValue(for: .meter())
        }
        let windowStart = workout.startDate
        let windowEnd = workout.endDate
        async let routeTask = routePoints(for: workout)
        async let cadenceTask = cadenceStepsPerMinute(for: workout)
        async let heartSamples = quantitySamples(.heartRate, unit: beatsPerMinute, start: windowStart, end: windowEnd)
        async let stepSamples = quantitySamples(.stepCount, unit: .count(), start: windowStart, end: windowEnd)
        async let strideSamples = quantitySamples(.runningStrideLength, unit: .meter(), start: windowStart, end: windowEnd)
        async let powerSamples = quantitySamples(.runningPower, unit: .watt(), start: windowStart, end: windowEnd)
        async let contactSamples = quantitySamples(.runningGroundContactTime, unit: .second(), start: windowStart, end: windowEnd)
        async let oscillationSamples = quantitySamples(.runningVerticalOscillation, unit: .meter(), start: windowStart, end: windowEnd)
        async let linkedDistance = distanceSamples(for: workout)

        let route = await routeTask
        let stepCadence = await cadenceTask
        let heartRate = HealthSeries.instantaneous(await heartSamples, workoutStart: windowStart, workoutEnd: windowEnd)
        let cadenceSeries = HealthSeries.cadence(stepSamples: await stepSamples, workoutStart: windowStart, workoutEnd: windowEnd)
        let stride = HealthSeries.instantaneous(await strideSamples, workoutStart: windowStart, workoutEnd: windowEnd)
        let power = HealthSeries.instantaneous(await powerSamples, workoutStart: windowStart, workoutEnd: windowEnd)
        let groundContact = HealthSeries.groundContactMilliseconds(await contactSamples, workoutStart: windowStart, workoutEnd: windowEnd)
        let verticalOscillation = HealthSeries.verticalOscillationMillimeters(
            await oscillationSamples,
            workoutStart: windowStart,
            workoutEnd: windowEnd
        )
        let moving = workout.duration
        let training = moving.isFinite && moving > 0 ? moving : 0
        let pauses = pauseIntervals(for: workout)
        let laps = lapMarks(for: workout)
        let track = HealthSeries.track(
            route: route,
            distanceSamples: await linkedDistance,
            workoutStart: windowStart,
            workoutEnd: windowEnd,
            referenceDistanceMeters: distance,
            heartRate: heartRate,
            cadence: cadenceSeries,
            trainingDuration: training,
            pauses: pauses,
            laps: laps
        )
        return WorkoutRecord(
            id: UUID(),
            sport: sport,
            start: windowStart,
            end: windowEnd,
            distanceMeters: distance,
            energyKilocalories: energy,
            averageHeartRate: TrainingSeriesMath.displayAverage(stored: heart, points: heartRate),
            averageCadence: stepCadence,
            elevationGainMeters: climb,
            route: route,
            splits: track.splits,
            heartRate: heartRate,
            cadenceSeries: cadenceSeries,
            paceSeries: track.pace,
            stride: stride,
            elevation: track.elevation,
            groundContact: groundContact,
            power: power,
            verticalOscillation: verticalOscillation,
            origin: .apple,
            healthKitUUID: workout.uuid.uuidString,
            trainingDurationSeconds: training,
            conditions: nil,
            startPlace: nil,
            distanceProgress: track.distanceProgress,
            pauseIntervals: track.pauseIntervals,
            lapMarks: laps
        )
    }

    /// Distance samples that belong to the workout. A time-range query is the fallback
    /// when HealthKit did not link the samples to the workout object.
    private static func distanceSamples(for workout: HKWorkout) async -> [HealthQuantitySample] {
        let linked = await quantitySamples(
            .distanceWalkingRunning,
            unit: .meter(),
            predicate: HKQuery.predicateForObjects(from: workout)
        )
        if linked.contains(where: { $0.value.isFinite && $0.value > 0 }) {
            return linked
        }
        return await quantitySamples(
            .distanceWalkingRunning,
            unit: .meter(),
            start: workout.startDate,
            end: workout.endDate
        )
    }

    /// Manual pauses and motion pauses. Resume closes the open mark.
    /// An event that already has a duration is a finished pause on its own.
    private static func pauseIntervals(for workout: HKWorkout) -> [WorkoutPause] {
        let origin = workout.startDate
        let elapsed = workout.endDate.timeIntervalSince(origin)
        let marks = (workout.workoutEvents ?? []).compactMap { event -> WorkoutPause.Mark? in
            let second = event.dateInterval.start.timeIntervalSince(origin)
            let duration = event.dateInterval.duration
            switch event.type {
            case .pause, .motionPaused:
                return WorkoutPause.Mark(second: second, isResume: false, duration: duration)
            case .resume, .motionResumed:
                return WorkoutPause.Mark(second: second, isResume: true, duration: 0)
            default:
                return nil
            }
        }
        return WorkoutPause.intervals(from: marks, elapsed: elapsed)
    }

    /// Lap events mark the kilometer boundaries when each lap is about 1 km.
    /// Segment events are the same kind of mark on newer watches, and are used
    /// only when the workout recorded no laps. The end of the event is the boundary.
    private static func lapMarks(for workout: HKWorkout) -> [WorkoutLapMark] {
        let origin = workout.startDate
        let events = workout.workoutEvents ?? []
        let laps = events.filter { $0.type == .lap }
        let chosen = laps.isEmpty ? events.filter { $0.type == .segment } : laps
        return chosen.compactMap { event in
            let second = event.dateInterval.end.timeIntervalSince(origin)
            guard second.isFinite, second > 0 else { return nil }
            var meters = 0.0
            if let quantity = event.metadata?[HKMetadataKeyLapLength] as? HKQuantity {
                let value = quantity.doubleValue(for: .meter())
                if value.isFinite, value > 0 { meters = value }
            }
            return WorkoutLapMark(second: second, distanceMeters: meters)
        }
    }

    /// Samples that start inside the workout. A failed query returns none.
    private static func quantitySamples(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async -> [HealthQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await quantitySamples(identifier, unit: unit, predicate: predicate)
    }

    private static func quantitySamples(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        predicate: NSPredicate
    ) async -> [HealthQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let raw = samples as? [HKQuantitySample] ?? []
                // Leave HealthKit's callback queue before mapping or resuming.
                // Resuming inline continues the import on that queue, and the next
                // query can then deadlock waiting for the same queue.
                callbackHop.async {
                    let mapped = raw.compactMap { sample -> HealthQuantitySample? in
                        let value = sample.quantity.doubleValue(for: unit)
                        guard value.isFinite else { return nil }
                        return HealthQuantitySample(start: sample.startDate, end: sample.endDate, value: value)
                    }
                    continuation.resume(returning: mapped)
                }
            }
            execute(query)
        }
    }

    private static func sum(_ workout: HKWorkout, identifier: HKQuantityTypeIdentifier, unit: HKUnit) -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: unit)
    }

    private static func average(_ workout: HKWorkout, identifier: HKQuantityTypeIdentifier, unit: HKUnit) -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return workout.statistics(for: type)?.averageQuantity()?.doubleValue(for: unit)
    }

    private static func routePoints(for workout: HKWorkout) async -> [GeoPoint] {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let bag = PointBag()
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                guard let route = samples?.first as? HKWorkoutRoute else {
                    once.resume { hop([GeoPoint](), to: continuation) }
                    return
                }
                let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                    if let locations {
                        bag.append(locations)
                    }
                    if done || error != nil {
                        let snapshot = bag.snapshot()
                        once.resume { hop(snapshot, to: continuation) }
                    }
                }
                // Not `store.execute` here. This handler is on HealthKit's serial
                // callback queue; starting the route query before the handler
                // returns deadlocks that queue, so the import never reaches merge.
                execute(routeQuery)
            }
            execute(query)
        }
    }

    /// HealthKit callbacks stay on HealthKit's queue. Resume and `execute` hop
    /// off it so a handler cannot run the rest of the import inline, and so a
    /// nested route query is not started on the queue that is still in the handler.
    private static let callbackHop = DispatchQueue(label: "sky.health.callback", qos: .userInitiated)

    private static func execute(_ query: HKQuery) {
        callbackHop.async {
            store.execute(query)
        }
    }

    private static func hop<T>(
        _ value: T,
        to continuation: CheckedContinuation<T, Never>
    ) {
        callbackHop.async {
            continuation.resume(returning: value)
        }
    }

    private static func hop<T>(
        _ result: Result<T, Error>,
        to continuation: CheckedContinuation<T, Error>
    ) {
        callbackHop.async {
            continuation.resume(with: result)
        }
    }

    private static func latestHeartRate() async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let sample = samples?.first as? HKQuantitySample
                continuation.resume(returning: sample?.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Live workout. Streams heart-rate samples stamped at or after `start`.
    /// Used when the phone builder has no sensor of its own but the watch (or a
    /// Bluetooth strap) is writing into HealthKit during this session.
    final class LiveHeartProbe {
        var onHeart: ((Double) -> Void)?
        private var query: HKAnchoredObjectQuery?
        private let unit = HKUnit.count().unitDivided(by: .minute())

        func start(from start: Date) {
            stop()
            guard AppleHealth.available else { return }
            guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: nil,
                limit: HKObjectQueryNoLimit
            ) { [weak self] _, samples, _, _, _ in
                self?.emit(samples)
            }
            query.updateHandler = { [weak self] _, samples, _, _, _ in
                self?.emit(samples)
            }
            self.query = query
            AppleHealth.store.execute(query)
        }

        func stop() {
            if let query {
                AppleHealth.store.stop(query)
            }
            query = nil
        }

        private func emit(_ samples: [HKSample]?) {
            guard let samples = samples as? [HKQuantitySample], let latest = samples.max(by: { $0.endDate < $1.endDate }) else {
                return
            }
            let bpm = latest.quantity.doubleValue(for: unit)
            guard bpm.isFinite, bpm > 0 else { return }
            let handler = onHeart
            DispatchQueue.main.async {
                handler?(bpm)
            }
        }
    }

    private static func stepCountToday() async -> Int? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                let steps = stats?.sumQuantity()?.doubleValue(for: .count())
                continuation.resume(returning: steps.map { Int($0.rounded()) })
            }
            store.execute(query)
        }
    }

    private static func sleepHours() async -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let start = Date().addingTimeInterval(-36 * 60 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let asleep: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                    1 // older asleep samples
                ]
                let seconds = (samples as? [HKCategorySample] ?? []).reduce(0.0) { partial, sample in
                    guard asleep.contains(sample.value) else { return partial }
                    return partial + sample.endDate.timeIntervalSince(sample.startDate)
                }
                continuation.resume(returning: seconds > 0 ? seconds / 3600 : nil)
            }
            store.execute(query)
        }
    }

    private static var shareTypes: Set<HKSampleType> {
        // save(route:) writes an HKWorkoutRoute, so share permission has to include the series type.
        var types: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for identifier in [HKQuantityTypeIdentifier.heartRate, .activeEnergyBurned, .distanceWalkingRunning, .stepCount] {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    private static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        let quantities: [HKQuantityTypeIdentifier] = [
            .heartRate, .activeEnergyBurned, .distanceWalkingRunning, .stepCount,
            .runningPower, .runningStrideLength, .runningGroundContactTime,
            .runningVerticalOscillation, .flightsClimbed
        ]
        for identifier in quantities {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }
}

extension SportKind {
    var hkActivity: HKWorkoutActivityType {
        switch self {
        case .outdoorRunning, .indoorRunning: return .running
        case .trailRunning: return .running
        case .hiking: return .hiking
        case .functionalStrength: return .functionalStrengthTraining
        case .hiit: return .highIntensityIntervalTraining
        case .other: return .other
        }
    }

    var hkLocationType: HKWorkoutSessionLocationType {
        usesOutdoorLocation ? .outdoor : .indoor
    }

    /// Maps a HealthKit workout, including indoor vs outdoor running metadata.
    static func from(_ workout: HKWorkout) -> SportKind {
        switch workout.workoutActivityType {
        case .running:
            if isTrailRun(workout) { return .trailRunning }
            return isIndoor(workout) ? .indoorRunning : .outdoorRunning
        case .hiking:
            return .hiking
        case .functionalStrengthTraining:
            return .functionalStrength
        case .highIntensityIntervalTraining:
            return .hiit
        default:
            return .other
        }
    }

    /// Activity type alone. Running without location metadata is outdoor.
    static func from(_ type: HKWorkoutActivityType) -> SportKind {
        switch type {
        case .running: return .outdoorRunning
        case .hiking: return .hiking
        case .functionalStrengthTraining: return .functionalStrength
        case .highIntensityIntervalTraining: return .hiit
        default: return .other
        }
    }

    /// Configuration from a mirrored or phone-started session.
    static func from(_ configuration: HKWorkoutConfiguration) -> SportKind {
        if configuration.activityType == .running {
            return configuration.locationType == .indoor ? .indoorRunning : .outdoorRunning
        }
        return from(configuration.activityType)
    }

    /// HealthKit has no trail-run activity type. A trail run is saved as `.running`
    /// and tagged with this key so the app can tell it from an outdoor run.
    static let trailRunMetadataKey = "SkyWandererTrailRun"

    private static func isTrailRun(_ workout: HKWorkout) -> Bool {
        (workout.metadata?[trailRunMetadataKey] as? NSNumber)?.boolValue ?? false
    }

    private static func isIndoor(_ workout: HKWorkout) -> Bool {
        if let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? NSNumber {
            return indoor.boolValue
        }
        if let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool {
            return indoor
        }
        return false
    }
}

final class AppleWorkoutRecorder: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    struct Reading {
        var heartRate: Double?
        var distance: Double?
        var steps: Double?
        var energy: Double?
        var power: Double?
        var stride: Double?
        var groundContactMilliseconds: Double?
        /// Millimeters, matching the detail chart.
        var verticalOscillationMillimeters: Double?
    }

    var onReading: ((Reading) -> Void)?
    var onFailure: ((String) -> Void)?

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var collecting = false

    func start(sport: SportKind) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = sport.hkActivity
        configuration.locationType = sport.hkLocationType
        let session = try HKWorkoutSession(healthStore: AppleHealth.store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        try await begin(session: session, builder: builder, configuration: configuration, start: Date())
    }

    /// Mirrored session the watch already started. Do not start the activity again or move its start date.
    func adoptMirrored(_ session: HKWorkoutSession) async throws {
        let configuration = session.workoutConfiguration
        let builder = session.associatedWorkoutBuilder()
        let start = session.startDate ?? Date()
        builder.dataSource = Self.makeDataSource(configuration)
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
        let alreadyRunning = session.state == .running || session.state == .paused
        if !alreadyRunning {
            session.startActivity(with: start)
        }
        do {
            try await collect(builder, from: start)
            collecting = true
        } catch {
            let running = alreadyRunning || session.state == .running || session.state == .paused
            if running {
                collecting = true
                return
            }
            discard()
            throw error
        }
    }

    static func makeDataSource(_ configuration: HKWorkoutConfiguration) -> HKLiveWorkoutDataSource {
        let dataSource = HKLiveWorkoutDataSource(healthStore: AppleHealth.store, workoutConfiguration: configuration)
        let identifiers: [HKQuantityTypeIdentifier] = [
            .heartRate, .stepCount, .distanceWalkingRunning, .activeEnergyBurned,
            .runningPower, .runningStrideLength, .runningGroundContactTime, .runningVerticalOscillation
        ]
        for identifier in identifiers {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                dataSource.enableCollection(for: type, predicate: nil)
            }
        }
        return dataSource
    }

    private func begin(
        session: HKWorkoutSession,
        builder: HKLiveWorkoutBuilder,
        configuration: HKWorkoutConfiguration,
        start: Date
    ) async throws {
        builder.dataSource = Self.makeDataSource(configuration)
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
        session.startActivity(with: start)
        do {
            try await collect(builder, from: start)
            collecting = true
        } catch {
            discard()
            throw error
        }
    }

    private func collect(_ builder: HKLiveWorkoutBuilder, from start: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: start) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RecorderError.failed)
                }
            }
        }
    }

    func pause() {
        session?.pause()
    }

    func resume() {
        session?.resume()
    }

    var isSessionOpen: Bool { session != nil }

    /// Ends the session without `finishWorkout`, so Health does not keep a workout or route.
    func discard() {
        guard let session, let builder else { return }
        let wasCollecting = collecting
        collecting = false
        self.session = nil
        self.builder = nil
        if wasCollecting {
            builder.discardWorkout()
        }
        session.end()
    }

    struct FinishOutcome {
        var healthID: String?
        var routeError: String?
    }

    /// Set for a trail run so the saved running workout carries `SportKind.trailRunMetadataKey`.
    var tagsTrailRun = false

    func finish(route: [GeoPoint]) async -> FinishOutcome {
        guard let session, let builder else { return FinishOutcome(healthID: nil, routeError: nil) }
        collecting = false
        session.end()
        if tagsTrailRun {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                builder.addMetadata([SportKind.trailRunMetadataKey: true]) { _, _ in
                    continuation.resume()
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            builder.endCollection(withEnd: Date()) { _, _ in
                continuation.resume()
            }
        }
        let workout: HKWorkout? = await withCheckedContinuation { continuation in
            builder.finishWorkout { workout, _ in
                continuation.resume(returning: workout)
            }
        }
        self.session = nil
        self.builder = nil
        var routeError: String?
        if let workout, route.count >= 2 {
            do {
                try await save(route: route, workout: workout)
            } catch {
                routeError = error.localizedDescription
            }
        }
        return FinishOutcome(healthID: workout?.uuid.uuidString, routeError: routeError)
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        onFailure?(error.localizedDescription)
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        onReading?(reading(from: workoutBuilder))
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    private func reading(from builder: HKLiveWorkoutBuilder) -> Reading {
        Reading(
            heartRate: recent(builder, .heartRate, HKUnit.count().unitDivided(by: .minute())),
            distance: sum(builder, .distanceWalkingRunning, .meter()),
            steps: sum(builder, .stepCount, .count()),
            energy: sum(builder, .activeEnergyBurned, .kilocalorie()),
            power: recent(builder, .runningPower, .watt()),
            stride: recent(builder, .runningStrideLength, .meter()),
            groundContactMilliseconds: recent(builder, .runningGroundContactTime, .second()).map { $0 * 1000 },
            verticalOscillationMillimeters: recent(builder, .runningVerticalOscillation, .meter()).map { $0 * 1000 }
        )
    }

    private func recent(_ builder: HKLiveWorkoutBuilder, _ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return builder.statistics(for: type)?.mostRecentQuantity()?.doubleValue(for: unit)
    }

    private func sum(_ builder: HKLiveWorkoutBuilder, _ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return builder.statistics(for: type)?.sumQuantity()?.doubleValue(for: unit)
    }

    private func save(route: [GeoPoint], workout: HKWorkout) async throws {
        let locations = route.map { point in
            CLLocation(
                coordinate: point.coordinate,
                altitude: point.altitude,
                horizontalAccuracy: 8,
                verticalAccuracy: 8,
                timestamp: point.timestamp ?? Date()
            )
        }
        let builder = HKWorkoutRouteBuilder(healthStore: AppleHealth.store, device: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.insertRouteData(locations) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: RecorderError.failed)
                    return
                }
                builder.finishRoute(with: workout, metadata: nil) { saved, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if saved == nil {
                        continuation.resume(throwing: RecorderError.failed)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

private final class PointBag: @unchecked Sendable {
    private(set) var points: [GeoPoint] = []
    private let lock = NSLock()

    func append(_ locations: [CLLocation]) {
        lock.lock()
        points.append(contentsOf: locations.map { location in
            GeoPoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                timestamp: location.timestamp
            )
        })
        lock.unlock()
    }

    func snapshot() -> [GeoPoint] {
        lock.lock()
        defer { lock.unlock() }
        return points
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()

    func resume(_ body: () -> Void) {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        // Unlock first. `body` resumes the import, and holding the lock across
        // that resume deadlocks if the import touches this gate again on the
        // same thread.
        body()
    }
}
