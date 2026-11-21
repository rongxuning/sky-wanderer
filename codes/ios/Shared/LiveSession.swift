import Combine
import CoreLocation
import CoreMotion
import Foundation

/// Where the current heart-rate number can come from. The phone has no sensor of its own.
enum LiveHeartSource: Equatable {
    case unknown
    case watch
    case none
}

/// Lock-screen activity. The phone app sets this; the watch leaves it nil.
@MainActor
protocol LiveActivitySink: AnyObject {
    func noteLive(
        sportTitle: String,
        elapsed: TimeInterval,
        distanceMeters: Double,
        paceSecPerKm: Double,
        heartRate: Double,
        paused: Bool
    )
    func endLive()
}

@MainActor
final class LiveSession: ObservableObject {
    enum Phase {
        case idle
        case running
        case finished
    }

    let sport: SportKind
    let plannedRoute: [GeoPoint]
    let memberProfiles: [TeammateProfile]

    @Published var phase: Phase = .idle
    @Published var paused = false
    @Published var simulating = false
    @Published var statusText = ""
    @Published var elapsed: TimeInterval = 0
    @Published var distanceMeters: Double = 0
    @Published var paceSecPerKm: Double = 0
    @Published var heartRate: Double = 0
    /// `.none` means this session has no heart-rate sensor. Never filled from older Health samples.
    @Published var heartSource: LiveHeartSource = .unknown
    @Published var cadence: Double = 0
    @Published var energyKilocalories: Double = 0
    @Published var elevationGainMeters: Double = 0
    @Published var elevationLossMeters: Double = 0
    /// Latest GPS altitude in meters. The watch companion screen shows this as 实时海拔.
    @Published var altitudeMeters: Double = 0
    /// Heart-rate samples taken while moving. The live sheet plots these.
    @Published private(set) var heartSeries: [SeriesPoint] = []
    /// Cadence samples taken while moving, in steps per minute.
    @Published private(set) var cadenceSeries: [SeriesPoint] = []
    /// Downsampled for the map. The saved record and the HealthKit route use `recordedRoute`.
    @Published var route: [GeoPoint] = []
    /// Latest accepted fix. The live map recenters on this, including before the track has two points.
    @Published var userFix: GeoPoint?
    @Published var splits: [KilometerSplit] = []
    /// Where each full kilometer ended. The live map draws one numbered disc per entry.
    @Published private(set) var kilometerMarks: [KilometerMarker] = []
    @Published var teammates: [TeammateLive] = []
    private(set) var routeSaveWarning: String?
    weak var liveActivity: LiveActivitySink?
    /// Phone → Watch live mirror. The watch target leaves this nil.
    weak var watchMirror: PhoneWatchLiveSink?

    private let recorder = AppleWorkoutRecorder()
    private let sync: TeammateSync = LocalTeammateSimulator()
    private let pedometer = CMPedometer()
    private let location = CLLocationManager()
    private let locationProxy = LocationProxy()
    /// HealthKit samples from the watch or a Bluetooth strap while this session runs.
    private let heartProbe = AppleHealth.LiveHeartProbe()
    private var timer: Timer?
    private var startedAt = Date()
    private var runningSince: Date?
    private var banked: TimeInterval = 0
    private var gpsDistance = 0.0
    private var healthDistance = 0.0
    private var lastLocation: CLLocation?
    private var lastAltitude: Double?
    /// Thresholded climb/drop. Raw GPS altitude still updates `altitudeMeters` for display.
    private var elevationTotals = ElevationNoise.Totals()
    /// First fix after resume is the cached pre-pause coordinate. Do not anchor on it.
    private var ignoreNextLocation = false
    /// Samples stamped before this were taken during the pause.
    private var resumeAnchorDate = Date.distantPast
    private var splitStartDistance = 0.0
    private var splitStartElapsed: TimeInterval = 0
    private var splitStartEnergy = 0.0
    private var splitHearts: [Double] = []
    private var splitCadences: [Double] = []
    private var paceSeries: [SeriesPoint] = []
    private var strideSeries: [SeriesPoint] = []
    private var elevationSeries: [SeriesPoint] = []
    private var contactSeries: [SeriesPoint] = []
    private var powerSeries: [SeriesPoint] = []
    private var oscillationSeries: [SeriesPoint] = []
    private var stepCount = 0.0
    /// Watch step totals. Phone pedometer cadence is ignored while this window is still fresh.
    private var watchStepsAnchor: (count: Double, date: Date)?
    private var watchCadenceFreshUntil = Date.distantPast
    private var latestPower = 0.0
    private var latestStride = 0.0
    private var latestContact = 0.0
    private var latestOscillation = 0.0
    private var simHeading = 0.4
    private var simPoint = SampleLibrary.plannedRoutes(around: MapOrigin.fallback)[0].points.first ?? MapOrigin.fallback
    private var sampleTick = 0
    private var usedApple = false
    /// Mirrored watch session is producing this workout. Phone pedometer is only the fallback.
    private var preferWatchMetrics = false
    private var leavingApple = false
    private var teammatesStarted = false
    /// Every accepted point. Display uses a downsample of this.
    private var recordedRoute: [GeoPoint] = []

    init(sport: SportKind, plannedRoute: [GeoPoint], teammates: [TeammateProfile]) {
        self.sport = sport
        self.plannedRoute = plannedRoute
        self.memberProfiles = teammates
        simPoint = MapOrigin.fallback
    }

    var currentSplit: KilometerSplit {
        let deltaDistance = max(0, distanceMeters - splitStartDistance)
        let deltaTime = max(0, elapsed - splitStartElapsed)
        let pace = deltaDistance > 15 ? deltaTime / (deltaDistance / 1000) : 0
        return KilometerSplit(
            index: splits.count + 1,
            paceSecPerKm: pace,
            cadence: mean(splitCadences),
            heartRate: mean(splitHearts),
            partial: true,
            energyKilocalories: burnedThisSplit,
            distanceMeters: deltaDistance,
            durationSeconds: deltaTime
        )
    }

    /// Active kilocalories since the current kilometer started.
    private var burnedThisSplit: Double {
        let burned = energyKilocalories - splitStartEnergy
        guard burned.isFinite, burned > 0 else { return 0 }
        return burned
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .running
        startedAt = Date()
        runningSince = Date()
        wireCallbacks()
        startTimer()
        publishLive()
        // Location stays off until HealthKit either starts or we choose simulation.
        // Points collected before that choice were being kept, then simulation jumped
        // to the fallback origin and appended a fake track onto them.
        if AppleHealth.available {
            do {
                try await AppleHealth.authorize()
                guard phase == .running else { return }
                // GPS starts before the watch answers, so the first seconds of the track are not dropped.
                startPedometer()
                startLocation()
                if await adoptMirroredWatch() {
                    startHeartProbe()
                    scheduleTeammates()
                    return
                }
                guard phase == .running else { return }
                try await recorder.start(sport: sport)
                guard phase == .running else {
                    // stop() already kept a record with no HealthKit id. Do not save this session.
                    recorder.discard()
                    return
                }
                usedApple = true
                // Stay `.unknown` until a sample arrives or the sheet times out to 「无来源」.
                // A lingering watch workout or Bluetooth strap can still feed HealthKit.
                heartSource = .unknown
                simulating = false
                statusText = ""
                startHeartProbe()
            } catch {
                guard phase == .running else { return }
                beginSimulation("健康数据没有启动，已改用本地模拟")
            }
        } else {
            beginSimulation("这台设备没有健康数据，已改用本地模拟")
        }
        guard phase == .running else { return }
        scheduleTeammates()
    }

    /// Reads heart-rate samples written during this workout (mirrored watch, lingering
    /// watch session, or a paired Bluetooth strap). Does not invent older resting samples.
    private func startHeartProbe() {
        heartProbe.onHeart = { [weak self] bpm in
            Task { @MainActor in
                self?.applyProbedHeart(bpm)
            }
        }
        heartProbe.start(from: startedAt)
    }

    private func applyProbedHeart(_ bpm: Double) {
        guard phase == .running, !paused, !simulating, !leavingApple else { return }
        guard bpm > 0 else { return }
        heartRate = bpm
        splitHearts.append(bpm)
        if heartSource == .unknown || heartSource == .none {
            heartSource = .watch
        }
    }

    /// Phone asks the paired watch to record this workout. False on watchOS, with no watch, or if mirroring does not start.
    private func adoptMirroredWatch() async -> Bool {
        #if os(iOS)
        guard let mirrored = await WatchWorkoutBridge.mirroredSession(for: sport) else { return false }
        guard phase == .running else {
            mirrored.end()
            return false
        }
        do {
            try await recorder.adoptMirrored(mirrored)
        } catch {
            recorder.discard()
            return false
        }
        guard phase == .running else {
            recorder.discard()
            return false
        }
        usedApple = true
        preferWatchMetrics = true
        heartSource = .watch
        simulating = false
        statusText = ""
        return true
        #else
        return false
        #endif
    }

    private func scheduleTeammates() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.phase == .running, !self.teammatesStarted else { return }
            if let location = self.lastLocation {
                self.startTeammates(at: GeoPoint(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitude: location.altitude,
                    timestamp: location.timestamp
                ))
            } else {
                self.startTeammates(at: MapOrigin.fallback)
            }
        }
    }

    /// Foreground return. Elapsed time is derived from the clock, and location is started again if the system stopped it.
    func catchUp() {
        guard phase == .running else { return }
        elapsed = movingTime(at: Date())
        publishLive()
        guard !paused, !simulating else { return }
        let status = location.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        startLocation()
    }

    func pause() {
        guard phase == .running, !paused else { return }
        let now = Date()
        elapsed = movingTime(at: now)
        banked = elapsed
        runningSince = nil
        paused = true
        stopLocationUpdates()
        lastLocation = nil
        lastAltitude = nil
        if usedApple { recorder.pause() }
        pedometer.stopUpdates()
        publishLive()
    }

    func resume() {
        guard phase == .running, paused else { return }
        runningSince = Date()
        paused = false
        if usedApple { recorder.resume() }
        publishLive()
        guard !simulating else { return }
        startPedometer()
        ignoreNextLocation = true
        resumeAnchorDate = Date()
        startLocation()
    }

    func stop() async -> WorkoutRecord {
        let stoppedAt: Date
        if phase == .running {
            let now = Date()
            elapsed = movingTime(at: now)
            banked = elapsed
            runningSince = nil
            stoppedAt = now
        } else {
            stoppedAt = startedAt.addingTimeInterval(max(0, elapsed))
        }
        phase = .finished
        timer?.invalidate()
        pedometer.stopUpdates()
        stopLocationUpdates()
        heartProbe.stop()
        heartProbe.onHeart = nil
        let leftover = distanceMeters - splitStartDistance
        if leftover > 30 {
            closeSplit(distance: leftover, partial: true)
        }
        leavingApple = true
        var healthID: String?
        if usedApple {
            let outcome = await recorder.finish(route: recordedRoute)
            healthID = outcome.healthID
            if let routeError = outcome.routeError {
                routeSaveWarning = "路线没有写入健康：\(routeError)"
                statusText = routeSaveWarning ?? ""
            }
        }
        usedApple = false
        sync.stop()
        liveActivity?.endLive()
        watchMirror?.endLive()
        return makeRecord(healthID: healthID, stoppedAt: stoppedAt)
    }

    /// Drops the Apple session without saving it, then records only simulated points.
    private func beginSimulation(_ reason: String) {
        guard phase == .running, !simulating, !leavingApple else { return }
        leavingApple = true
        usedApple = false
        stopLocationUpdates()
        pedometer.stopUpdates()
        heartProbe.stop()
        heartProbe.onHeart = nil
        if recorder.isSessionOpen {
            recorder.discard()
        }
        guard phase == .running else { return }
        statusText = reason
        resetTrack()
        simulating = true
        leavingApple = false
        simPoint = MapOrigin.fallback
        startTeammates(at: MapOrigin.fallback)
    }

    private func startTeammates(at origin: GeoPoint) {
        guard !teammatesStarted, !memberProfiles.isEmpty else { return }
        teammatesStarted = true
        sync.onChange = { [weak self] lives in
            Task { @MainActor in
                self?.teammates = lives
            }
        }
        sync.start(
            context: TeamSessionContext(teamID: UUID(), sport: sport, members: memberProfiles),
            origin: origin
        )
    }

    private func wireCallbacks() {
        recorder.onReading = { [weak self] reading in
            Task { @MainActor in
                self?.apply(reading)
            }
        }
        recorder.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self, self.phase == .running, !self.simulating, !self.leavingApple else { return }
                // A dropped watch session must not invent a track or a heart rate. Phone GPS and pedometer stay.
                if self.preferWatchMetrics {
                    self.preferWatchMetrics = false
                    // Probe can still pick up strap / residual HealthKit samples.
                    self.heartSource = self.heartRate > 0 ? .watch : .unknown
                    self.watchCadenceFreshUntil = .distantPast
                    self.watchStepsAnchor = nil
                    self.statusText = "手表锻炼中断，已改用手机传感器"
                    return
                }
                self.beginSimulation("锻炼中断（\(message)），已改用本地模拟")
            }
        }
        locationProxy.onLocation = { [weak self] location in
            Task { @MainActor in
                self?.apply(location)
            }
        }
        locationProxy.onAuthorization = { [weak self] manager in
            Task { @MainActor in
                self?.enableBackgroundLocation(manager)
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let data else { return }
            let cadence = (data.currentCadence?.doubleValue ?? 0) * 60
            let steps = data.numberOfSteps.doubleValue
            Task { @MainActor in
                guard let self, !self.simulating, !self.paused, !self.leavingApple else { return }
                let watchFresh = Date() < self.watchCadenceFreshUntil
                if cadence > 0, !watchFresh {
                    self.cadence = cadence
                    self.splitCadences.append(cadence)
                }
                if self.watchStepsAnchor == nil {
                    self.stepCount = steps
                }
            }
        }
    }

    private func startLocation() {
        location.delegate = locationProxy
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        location.pausesLocationUpdatesAutomatically = false
        #endif
        location.requestWhenInUseAuthorization()
        enableBackgroundLocation(location)
    }

    /// Background updates stay off until When In Use is granted. The delegate calls this again after the prompt.
    private func enableBackgroundLocation(_ manager: CLLocationManager) {
        guard phase == .running, !paused, !simulating else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        #endif
        manager.startUpdatingLocation()
    }

    private func stopLocationUpdates() {
        location.stopUpdatingLocation()
        #if os(iOS)
        location.allowsBackgroundLocationUpdates = false
        location.showsBackgroundLocationIndicator = false
        #endif
    }

    private func tick() {
        guard phase == .running, !paused, !leavingApple else { return }
        elapsed = movingTime(at: Date())
        if simulating {
            advanceSimulation()
        }
        refreshDistance()
        noteSplitProgress()
        sampleTick += 1
        if sampleTick % 5 == 0 {
            captureSample()
        }
        publishLive()
        if let last = route.last {
            sync.publish(AthleteSnapshot(
                latitude: last.latitude,
                longitude: last.longitude,
                paceSecPerKm: paceSecPerKm,
                heartRate: heartRate,
                date: Date()
            ))
        }
    }

    private func advanceSimulation() {
        let speed = sport == .running ? Double.random(in: 2.7...3.15) : Double.random(in: 1.15...1.45)
        simHeading += Double.random(in: -0.25...0.25)
        let north = cos(simHeading) * speed
        let east = sin(simHeading) * speed
        simPoint = simPoint.moved(northMeters: north, eastMeters: east)
        simPoint.altitude = 18 + 6 * sin(elapsed / 40)
        simPoint.timestamp = Date()
        gpsDistance += speed
        appendPoint(simPoint)
        userFix = simPoint
        paceSecPerKm = 1000 / speed
        heartRate = (sport == .running ? 156 : 118) + sin(elapsed / 12) * 6
        cadence = sport == .running ? 174 + sin(elapsed / 9) * 4 : 110 + sin(elapsed / 10) * 3
        // HealthKit is not feeding energy here. Rough display estimate only: 65 kcal/km running, 50 hiking.
        energyKilocalories = (gpsDistance / 1000) * (sport == .running ? 65 : 50)
        noteAltitude(simPoint.altitude)
        splitHearts.append(heartRate)
        splitCadences.append(cadence)
    }

    private func apply(_ reading: AppleWorkoutRecorder.Reading) {
        guard phase == .running, !paused, !simulating, !leavingApple else { return }
        if let heart = reading.heartRate, heart > 0 {
            heartRate = heart
            splitHearts.append(heart)
            if heartSource == .unknown || heartSource == .none {
                heartSource = .watch
            }
        }
        if let distance = reading.distance, distance > 0 {
            healthDistance = distance
        }
        if preferWatchMetrics, let steps = reading.steps {
            noteWatchSteps(steps)
        }
        if let energy = reading.energy, energy > 0 {
            energyKilocalories = energy
        }
        if let power = reading.power, power > 0 { latestPower = power }
        if let stride = reading.stride, stride > 0 { latestStride = stride }
        if let contact = reading.groundContactMilliseconds, contact > 0 { latestContact = contact }
        if let oscillation = reading.verticalOscillationMillimeters, oscillation > 0 { latestOscillation = oscillation }
        refreshDistance()
    }

    /// Current cadence from the watch workout's cumulative step count. Phone pedometer stays the fallback.
    private func noteWatchSteps(_ steps: Double) {
        guard steps.isFinite, steps >= 0 else { return }
        let now = Date()
        if let anchor = watchStepsAnchor {
            let span = now.timeIntervalSince(anchor.date)
            let delta = steps - anchor.count
            if span >= 3, delta >= 0 {
                let cadence = delta / (span / 60)
                if cadence >= 40, cadence <= 250 {
                    self.cadence = cadence
                    splitCadences.append(cadence)
                    watchCadenceFreshUntil = now.addingTimeInterval(8)
                }
                watchStepsAnchor = (steps, now)
            }
        } else {
            watchStepsAnchor = (steps, now)
        }
        if steps > stepCount { stepCount = steps }
    }

    private func apply(_ location: CLLocation) {
        guard phase == .running, !paused, !simulating, !leavingApple else { return }
        if ignoreNextLocation || location.timestamp < resumeAnchorDate {
            ignoreNextLocation = false
            return
        }
        guard location.horizontalAccuracy >= 0 else { return }
        let fix = GeoPoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            timestamp: location.timestamp
        )
        // Map follow uses every usable fix. Track and climb wait for real movement.
        userFix = fix
        guard location.horizontalAccuracy < 40 else { return }
        let moved: Double
        if let lastLocation {
            moved = location.distance(from: lastLocation)
        } else {
            moved = .infinity
        }
        // Standing still: GPS still wanders and altitude flutters ±10m. Do not grow
        // the track or climb totals until the person actually moves.
        let advancesTrack = moved > 0.8 && moved < 40
        let firstFix = lastLocation == nil
        guard firstFix || advancesTrack else {
            if location.altitude.isFinite {
                altitudeMeters = location.altitude
            }
            return
        }
        if advancesTrack {
            gpsDistance += moved
        }
        lastLocation = location
        startTeammates(at: fix)
        if location.speed > 0.4 {
            paceSecPerKm = 1000 / location.speed
        }
        appendPoint(fix)
        noteAltitude(location.altitude, verticalAccuracy: location.verticalAccuracy)
        refreshDistance()
    }

    private func appendPoint(_ point: GeoPoint) {
        recordedRoute.append(point)
        route = Self.displayRoute(recordedRoute)
    }

    /// Map display only. `recordedRoute` stays complete for the saved workout and HealthKit.
    private static func displayRoute(_ points: [GeoPoint]) -> [GeoPoint] {
        let limit = 600
        guard points.count > limit else { return points }
        let lastIndex = points.count - 1
        return (0..<limit).map { slot in
            let index = Int((Double(slot) * Double(lastIndex) / Double(limit - 1)).rounded())
            return points[index]
        }
    }

    private func resetTrack() {
        recordedRoute = []
        route = []
        gpsDistance = 0
        healthDistance = 0
        distanceMeters = 0
        paceSecPerKm = 0
        heartRate = 0
        cadence = 0
        energyKilocalories = 0
        elevationGainMeters = 0
        elevationLossMeters = 0
        altitudeMeters = 0
        lastLocation = nil
        lastAltitude = nil
        elevationTotals = ElevationNoise.Totals()
        userFix = nil
        ignoreNextLocation = false
        resumeAnchorDate = .distantPast
        splits = []
        kilometerMarks = []
        splitStartDistance = 0
        splitStartElapsed = 0
        splitStartEnergy = 0
        splitHearts = []
        splitCadences = []
        heartSeries = []
        cadenceSeries = []
        paceSeries = []
        strideSeries = []
        elevationSeries = []
        contactSeries = []
        powerSeries = []
        oscillationSeries = []
        stepCount = 0
        watchStepsAnchor = nil
        watchCadenceFreshUntil = .distantPast
        preferWatchMetrics = false
        heartSource = .unknown
        latestPower = 0
        latestStride = 0
        latestContact = 0
        latestOscillation = 0
        sampleTick = 0
        startedAt = Date()
        runningSince = Date()
        banked = 0
        elapsed = 0
    }

    private func refreshDistance() {
        distanceMeters = max(gpsDistance, healthDistance)
        if paceSecPerKm == 0, elapsed > 20, distanceMeters > 30 {
            paceSecPerKm = elapsed / (distanceMeters / 1000)
        }
    }

    private func noteAltitude(_ altitude: Double, verticalAccuracy: Double = 5) {
        guard altitude.isFinite else { return }
        altitudeMeters = altitude
        ElevationNoise.note(
            altitude: altitude,
            verticalAccuracy: verticalAccuracy,
            into: &elevationTotals
        )
        lastAltitude = elevationTotals.baselineMeters
        elevationGainMeters = elevationTotals.gainMeters
        elevationLossMeters = elevationTotals.lossMeters
    }

    private func noteSplitProgress() {
        let span = distanceMeters - splitStartDistance
        guard span.isFinite, span >= 1000, span < 400_000 else { return }
        let pendingKilometers = Int(span / 1000)
        guard pendingKilometers > 0 else { return }
        let energyEach = burnedThisSplit / Double(pendingKilometers)
        for _ in 0..<pendingKilometers {
            closeSplit(distance: 1000, partial: false, energy: energyEach)
            splitStartDistance += 1000
            splitStartElapsed = elapsed
            splitHearts = []
            splitCadences = []
        }
        splitStartEnergy = energyKilocalories
        markKilometer()
    }

    /// Pins the kilometer that just closed to the newest recorded point. Without a fix
    /// there is no pin. When several kilometers close in one tick, only the last has a
    /// known place.
    private func markKilometer() {
        let kilometer = splits.count
        guard let spot = recordedRoute.last else { return }
        kilometerMarks.append(KilometerMarker(
            kilometer: kilometer,
            latitude: spot.latitude,
            longitude: spot.longitude,
            altitude: spot.altitude,
            distanceMeters: Double(kilometer) * 1000
        ))
    }

    private func closeSplit(distance: Double, partial: Bool, energy: Double? = nil) {
        let deltaTime = max(1, elapsed - splitStartElapsed)
        let pace = deltaTime / (distance / 1000)
        let burned = energy ?? burnedThisSplit
        splits.append(KilometerSplit(
            index: splits.count + 1,
            paceSecPerKm: pace,
            cadence: mean(splitCadences),
            heartRate: mean(splitHearts),
            partial: partial,
            energyKilocalories: burned.isFinite && burned > 0 ? burned : 0,
            distanceMeters: distance,
            durationSeconds: deltaTime
        ))
    }

    private func captureSample() {
        let second = elapsed
        if heartRate > 0 { heartSeries.append(SeriesPoint(second: second, value: heartRate)) }
        if cadence > 0 { cadenceSeries.append(SeriesPoint(second: second, value: cadence)) }
        if paceSecPerKm > 0 { paceSeries.append(SeriesPoint(second: second, value: paceSecPerKm)) }
        elevationSeries.append(SeriesPoint(second: second, value: lastAltitude ?? route.last?.altitude ?? 0))
        if simulating {
            let stride = sport == .running ? 1.12 + sin(elapsed / 15) * 0.06 : 0.76 + sin(elapsed / 18) * 0.04
            let contact = sport == .running ? 230 + sin(elapsed / 11) * 12 : 284 + sin(elapsed / 13) * 8
            let watts = sport == .running ? 240 + sin(elapsed / 8) * 20 : 148 + sin(elapsed / 9) * 12
            strideSeries.append(SeriesPoint(second: second, value: stride))
            contactSeries.append(SeriesPoint(second: second, value: contact))
            powerSeries.append(SeriesPoint(second: second, value: watts))
            if sport == .running {
                let oscillation = 84 + sin(elapsed / 10) * 6
                oscillationSeries.append(SeriesPoint(second: second, value: oscillation))
            }
        } else {
            if latestStride > 0 {
                strideSeries.append(SeriesPoint(second: second, value: latestStride))
            } else if cadence > 30, paceSecPerKm > 0 {
                let speed = 1000 / paceSecPerKm
                strideSeries.append(SeriesPoint(second: second, value: speed / (cadence / 60)))
            }
            if latestContact > 0 {
                contactSeries.append(SeriesPoint(second: second, value: latestContact))
            }
            if latestPower > 0 {
                powerSeries.append(SeriesPoint(second: second, value: latestPower))
            }
            if latestOscillation > 0 {
                oscillationSeries.append(SeriesPoint(second: second, value: latestOscillation))
            }
        }
    }

    private func publishLive() {
        let shownHeart = simulating ? 0 : heartRate
        liveActivity?.noteLive(
            sportTitle: sport.title,
            elapsed: elapsed,
            distanceMeters: distanceMeters,
            paceSecPerKm: paceSecPerKm,
            heartRate: shownHeart,
            paused: paused
        )
        watchMirror?.pushLive(PhoneWatchLiveSnapshot.from(
            sport: sport,
            elapsed: elapsed,
            distanceMeters: distanceMeters,
            paceSecPerKm: paceSecPerKm,
            heartRate: shownHeart,
            cadence: cadence,
            altitudeMeters: altitudeMeters,
            paused: paused,
            userFix: userFix,
            route: recordedRoute.isEmpty ? route : recordedRoute,
            kilometers: kilometerMarks
        ))
    }

    /// Moving time already banked, plus the current unpaused segment.
    private func movingTime(at date: Date) -> TimeInterval {
        guard !paused, let runningSince else { return max(banked, elapsed) }
        return banked + max(0, date.timeIntervalSince(runningSince))
    }

    private func makeRecord(healthID: String?, stoppedAt: Date) -> WorkoutRecord {
        let end = max(stoppedAt, startedAt)
        let wall = max(0, end.timeIntervalSince(startedAt))
        let moving = min(max(0, elapsed), wall)
        let hearts = heartSeries.map(\.value)
        // Headline cadence is total steps ÷ moving minutes. The series stays on the chart.
        let stepCadence = CadenceMath.stepsPerMinute(steps: stepCount, duration: max(moving, 1))
        return WorkoutRecord(
            id: UUID(),
            sport: sport,
            start: startedAt,
            end: end,
            distanceMeters: distanceMeters,
            energyKilocalories: energyKilocalories,
            averageHeartRate: TrainingSeriesMath.displayAverage(stored: mean(hearts), points: heartSeries),
            averageCadence: stepCadence > 0
                ? stepCadence
                : TrainingSeriesMath.displayAverage(stored: 0, points: cadenceSeries),
            elevationGainMeters: elevationGainMeters,
            route: recordedRoute,
            splits: splits,
            heartRate: heartSeries,
            cadenceSeries: cadenceSeries,
            paceSeries: paceSeries,
            stride: strideSeries,
            elevation: elevationSeries,
            groundContact: contactSeries,
            power: powerSeries,
            verticalOscillation: oscillationSeries,
            origin: simulating ? .simulated : .apple,
            healthKitUUID: healthID,
            trainingDurationSeconds: moving
        )
    }

    private func mean(_ values: [Double]) -> Double {
        let usable = values.filter { $0 > 0 }
        guard !usable.isEmpty else { return 0 }
        return usable.reduce(0, +) / Double(usable.count)
    }
}

enum MapOrigin {
    static let fallback = GeoPoint(latitude: 31.240, longitude: 121.490, altitude: 12, timestamp: nil)
}

final class LocationProxy: NSObject, CLLocationManagerDelegate {
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorization: ((CLLocationManager) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        onLocation?(location)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?(manager)
    }
}
