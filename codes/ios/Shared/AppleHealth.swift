import CoreLocation
import Foundation
import HealthKit

/// Brand extension point. Phase 1 only builds `AppleActivitySource`.
/// A later brand implements this and is constructed beside Apple — the views
/// read workouts, they do not talk to HealthKit directly.
protocol ActivitySource {
    var brandName: String { get }
    func prepare() async throws
    func importRunsAndHikes() async throws -> [WorkoutRecord]
}

struct AppleActivitySource: ActivitySource {
    var brandName: String { "Apple" }

    func prepare() async throws {
        try await AppleHealth.authorize()
    }

    func importRunsAndHikes() async throws -> [WorkoutRecord] {
        try await AppleHealth.importRunsAndHikes()
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

    static func importRunsAndHikes() async throws -> [WorkoutRecord] {
        guard available else { return [] }
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                HKQuery.predicateForWorkouts(with: .running),
                HKQuery.predicateForWorkouts(with: .hiking)
            ])
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: 80,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        var records: [WorkoutRecord] = []
        for workout in workouts {
            guard let sport = SportKind.from(workout.workoutActivityType) else { continue }
            records.append(await record(from: workout, sport: sport))
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
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
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
                let mapped = (samples as? [HKQuantitySample] ?? []).compactMap { sample -> HealthQuantitySample? in
                    let value = sample.quantity.doubleValue(for: unit)
                    guard value.isFinite else { return nil }
                    return HealthQuantitySample(start: sample.startDate, end: sample.endDate, value: value)
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
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
                    once.resume { continuation.resume(returning: []) }
                    return
                }
                let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                    if let locations {
                        bag.append(locations)
                    }
                    if done || error != nil {
                        once.resume { continuation.resume(returning: bag.points) }
                    }
                }
                store.execute(routeQuery)
            }
            store.execute(query)
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
        for identifier in [HKQuantityTypeIdentifier.heartRate, .activeEnergyBurned, .distanceWalkingRunning] {
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
        case .running: return .running
        case .hiking: return .hiking
        }
    }

    static func from(_ type: HKWorkoutActivityType) -> SportKind? {
        switch type {
        case .running: return .running
        case .hiking: return .hiking
        default: return nil
        }
    }
}

final class AppleWorkoutRecorder: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    struct Reading {
        var heartRate: Double?
        var distance: Double?
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
        configuration.locationType = .outdoor
        let session = try HKWorkoutSession(healthStore: AppleHealth.store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        let dataSource = HKLiveWorkoutDataSource(healthStore: AppleHealth.store, workoutConfiguration: configuration)
        if let oscillation = HKQuantityType.quantityType(forIdentifier: .runningVerticalOscillation) {
            dataSource.enableCollection(for: oscillation, predicate: nil)
        }
        builder.dataSource = dataSource
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
        let start = Date()
        session.startActivity(with: start)
        do {
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
            collecting = true
        } catch {
            discard()
            throw error
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

    func finish(route: [GeoPoint]) async -> FinishOutcome {
        guard let session, let builder else { return FinishOutcome(healthID: nil, routeError: nil) }
        collecting = false
        session.end()
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
}

private final class ResumeOnce: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        body()
    }
}
