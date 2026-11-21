import HealthKit
import SwiftUI
import WatchKit

@main
struct SkyWandererWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) var delegate
    @StateObject private var app = WatchAppState()

    var body: some Scene {
        WindowGroup {
            WatchRoot()
                .environmentObject(app)
                .task {
                    WatchCompanionMirror.shared.activate()
                }
        }
    }
}

enum WatchPush: Hashable {
    case team
    case live(SportKind)
}

struct WatchRoot: View {
    @ObservedObject private var companion = WatchCompanionMirror.shared

    var body: some View {
        // Same SF Symbols as the phone glass tab bar: book / figure.run / map, plus 我的.
        TabView {
            NavigationStack {
                WatchStartView()
            }
            .tabItem {
                Label("训练", systemImage: "figure.run")
            }
            NavigationStack {
                WatchListView()
            }
            .tabItem {
                Label("记录", systemImage: "book")
            }
            NavigationStack {
                WatchRoutesView()
            }
            .tabItem {
                Label("路线", systemImage: "map")
            }
            NavigationStack {
                WatchMeHomeView()
            }
            .tabItem {
                Label("我的", systemImage: "person.crop.circle")
            }
        }
        .tabViewStyle(.verticalPage)
        .fullScreenCover(isPresented: $companion.showingPhoneWorkout) {
            WatchPhoneLiveView(mirror: companion)
        }
    }
}

struct WatchStartView: View {
    @EnvironmentObject private var app: WatchAppState

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("训练", systemImage: "figure.run")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                NavigationLink(value: WatchPush.team) {
                    Text(app.members.isEmpty ? "组队" : "组队 \(app.members.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.omniCobalt)
                }
                .buttonStyle(.plain)
            }
            NavigationLink(value: WatchPush.live(.hiking)) {
                Text("徒步")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.omniCobalt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glass(radius: 24)
            }
            .buttonStyle(.plain)
            NavigationLink(value: WatchPush.live(.running)) {
                Text("跑步")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.omniCobalt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glass(radius: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .background(CanvasBackground())
        .navigationTitle("训练")
        .navigationDestination(for: WatchPush.self) { push in
            switch push {
            case .team:
                WatchTeamView()
            case .live(let sport):
                WatchLiveView(sport: sport, teammates: app.members)
            }
        }
    }
}

struct WatchTeamView: View {
    @EnvironmentObject private var app: WatchAppState

    var body: some View {
        List {
            ForEach(SampleLibrary.teammates) { person in
                Button {
                    app.toggleTeammate(person.id)
                } label: {
                    HStack {
                        Text(person.name)
                        Spacer()
                        if app.members.contains(where: { $0.id == person.id }) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.omniCobalt)
                        }
                    }
                }
            }
        }
        .navigationTitle("组队")
    }
}

struct WatchLiveView: View {
    @EnvironmentObject private var app: WatchAppState
    @Environment(\.dismiss) private var dismiss
    var sport: SportKind
    @StateObject private var session: LiveSession
    @State private var started = false
    @State private var routeWarning: String?

    init(sport: SportKind, teammates: [TeammateProfile]) {
        self.sport = sport
        _session = StateObject(wrappedValue: LiveSession(
            sport: sport,
            plannedRoute: [],
            teammates: teammates
        ))
    }

    var body: some View {
        TabView {
            WatchLiveMetricsPage(
                sportTitle: sport.title,
                elapsed: session.elapsed,
                distanceMeters: session.distanceMeters,
                paceSecPerKm: session.paceSecPerKm,
                heartRate: session.heartRate,
                cadence: session.cadence,
                altitudeMeters: session.altitudeMeters,
                paused: session.paused,
                status: session.simulating ? "本地模拟" : (session.statusText.isEmpty ? nil : session.statusText),
                onEnd: { Task { await end() } }
            )
            .background(CanvasBackground())
            .navigationBarBackButtonHidden(true)
            WatchLiveMapPage(
                route: session.route,
                kilometers: session.kilometerMarks,
                showsUser: !session.simulating,
                userFix: session.userFix,
                courseDegrees: session.courseDegrees,
                userName: app.database.accounts.first(where: { $0.retiredAt == nil })?.name ?? ""
            )
            .navigationBarBackButtonHidden(true)
        }
        .tabViewStyle(.verticalPage)
        .navigationBarBackButtonHidden(true)
        .task {
            guard !started else { return }
            started = true
            await session.start()
        }
        .alert("路线没有写入健康", isPresented: Binding(
            get: { routeWarning != nil },
            set: { if !$0 { routeWarning = nil } }
        )) {
            Button("好") { dismiss() }
        } message: {
            Text(routeWarning ?? "")
        }
    }

    private func end() async {
        let record = await session.stop()
        app.add(record)
        if let warning = session.routeSaveWarning {
            routeWarning = warning
        } else {
            dismiss()
        }
    }
}

struct WatchListView: View {
    @EnvironmentObject private var app: WatchAppState
    @State private var window: StatsWindow = .week

    private var stats: TrainingStats {
        app.stats(for: window)
    }

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $window) {
                    ForEach(StatsWindow.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.navigationLink)
                Text("距离 \(Format.kilometers(stats.distanceMeters)) 公里")
                    .foregroundStyle(Color.skyMetricDistance)
                Text("心率 \(Format.integer(stats.averageHeartRate))")
                    .foregroundStyle(Color.skyMetricHeart)
                Text("爬升 \(stats.elevationGainMeters > 0 ? String(Int(stats.elevationGainMeters.rounded())) : "—") 米")
                    .foregroundStyle(Color.skyMetricElevation)
                Text("步频 \(Format.integer(stats.averageCadence))")
                    .foregroundStyle(Color.skyMetricPace)
            }
            if app.workouts.isEmpty {
                Text("还没有训练记录")
                    .foregroundStyle(Color.omniMuted)
            } else {
                ForEach(app.workouts) { workout in
                    NavigationLink(value: workout.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(workout.sport.title) · \(Format.relativeDayTime(workout.start))")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.omniMuted)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Format.kilometers(workout.distanceMeters))
                                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color.skyMetricDistance)
                                Text(Format.clock(workout.trainingDuration))
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.skyMetricDuration)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("记录")
        .navigationDestination(for: UUID.self) { id in
            if let workout = app.workouts.first(where: { $0.id == id }) {
                WatchDetailView(workout: workout)
            }
        }
        .task {
            await app.importFromApple()
        }
    }
}

struct WatchDetailView: View {
    var workout: WorkoutRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(workout.sport.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("\(Format.dayTime(workout.start)) · \(Format.duration(workout.trainingDuration))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Format.clock(workout.trainingDuration))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.skyMetricDuration)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Format.kilometers(workout.distanceMeters))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.skyMetricDistance)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    detailMetric(Format.pace(workout.averagePaceSecPerKm), color: .skyMetricPace)
                    detailMetric(Format.integer(workout.resolvedAverageHeartRate), color: .skyMetricHeart)
                }
                HStack(spacing: 8) {
                    detailMetric(Format.integer(workout.averageCadence), color: .skyMetricPace)
                    detailMetric(climbText, color: .skyMetricElevation)
                }
                RouteMap(
                    route: workout.route,
                    kilometers: RouteKilometers.markers(along: workout.route),
                    cornerRadius: 12,
                    hidesMapControls: true
                )
                .frame(height: 90)
                if workout.origin != .apple {
                    Text(workout.origin == .sample ? "示例" : "本地模拟")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.omniMuted)
                }
            }
            .padding(.horizontal, 4)
        }
        .background(CanvasBackground())
        .navigationTitle("详情")
    }

    private var climbText: String {
        guard workout.elevationGainMeters > 0.5 else { return "—" }
        return String(Int(workout.elevationGainMeters.rounded()))
    }

    private func detailMetric(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }
}

/// Phone `startWatchApp` delivers the configuration here. The watch records heart rate and steps; the phone mirrors them.
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        let sport = SportKind.from(workoutConfiguration.activityType) ?? .running
        Task { @MainActor in
            WatchCompanionMirror.shared.activate()
            WatchCompanionMirror.shared.notePhoneLaunch(sport: sport)
        }
        WatchMirroredWorkout.shared.start(workoutConfiguration)
    }
}

final class WatchMirroredWorkout: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    static let shared = WatchMirroredWorkout()

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var collecting = false

    func start(_ configuration: HKWorkoutConfiguration) {
        guard session == nil else { return }
        Task { @MainActor in
            await self.begin(configuration)
        }
    }

    @MainActor
    private func begin(_ configuration: HKWorkoutConfiguration) async {
        guard session == nil else { return }
        do {
            try await AppleHealth.authorize()
            let session = try HKWorkoutSession(healthStore: AppleHealth.store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = AppleWorkoutRecorder.makeDataSource(configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let start = Date()
            session.startActivity(with: start)
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
            session.startMirroringToCompanionDevice { [weak self] success, _ in
                guard !success else { return }
                Task { @MainActor in
                    self?.discard()
                }
            }
        } catch {
            discard()
        }
    }

    @MainActor
    private func discard() {
        let wasCollecting = collecting
        collecting = false
        let builder = self.builder
        let session = self.session
        self.builder = nil
        self.session = nil
        if wasCollecting {
            builder?.discardWorkout()
        }
        session?.end()
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in
            self.releaseAfterRemoteEnd(date)
        }
    }

    /// The phone finishes the mirrored workout. Close collection here, and do not finish or discard a second copy.
    @MainActor
    private func releaseAfterRemoteEnd(_ date: Date) {
        let builder = self.builder
        let wasCollecting = collecting
        session = nil
        self.builder = nil
        collecting = false
        WatchCompanionMirror.shared.apply(.idle())
        guard wasCollecting, let builder else { return }
        builder.endCollection(withEnd: date) { _, _ in }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.discard()
        }
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {}

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
