import Charts
import SwiftUI
import UIKit

struct LiveWorkoutView: View {
    @EnvironmentObject private var app: PhoneAppState
    @EnvironmentObject private var draft: WorkoutDraft
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: LiveSession?
    @State private var confirmEnd = false
    @State private var finished: WorkoutRecord?
    @State private var started = false

    var body: some View {
        ZStack {
            SkyTheme.Color.grouped
            if let session {
                LiveBody(session: session, confirmEnd: $confirmEnd)
            }
        }
        .navigationBarHidden(true)
        .navigationBarBackButtonHidden(true)
        .background(LivePopLock())
        .task {
            guard !started else { return }
            started = true
            let live = app.session(for: draft.sport, route: draft.plannedRoute(saved: app.savedRoutes, workouts: app.workouts).points, teammates: draft.members)
            live.liveActivity = WorkoutLiveActivityCenter.shared
            session = live
            await live.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session?.catchUp() }
        }
        .alert("结束这次运动？", isPresented: $confirmEnd) {
            Button("取消", role: .cancel) {}
            Button("结束", role: .destructive) {
                Task { await finish() }
            }
        }
        .sheet(item: $finished) { record in
            EndWorkoutSheet(record: record) { keepRoute in
                app.addWorkout(record)
                if keepRoute {
                    saveTrackAsRoute(record)
                }
                finished = nil
                app.noteFinished()
            }
            .interactiveDismissDisabled(true)
        }
    }

    private func finish() async {
        guard let session else { return }
        finished = await session.stop()
    }

    /// Checked on the end sheet. Reuses the GPX route store; an unchecked end does not call this.
    private func saveTrackAsRoute(_ record: WorkoutRecord) {
        let plannedID = draft.plannedRoute(saved: app.savedRoutes, workouts: app.workouts).id
        let course = app.savedRoutes.first(where: { $0.id == plannedID })?.waypoints ?? []
        let title = "\(record.sport.title) \(Format.dayTime(record.start))"
        guard let gpx = WorkoutTrackExport.gpx(name: title, points: record.route, course: course) else { return }
        let parsed = GPXFile.parse(gpx)
        _ = app.addGPXRoutes(parsed, source: gpx)
    }
}

private struct LiveBody: View {
    @ObservedObject var session: LiveSession
    @Binding var confirmEnd: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var dragTranslation: CGFloat = 0
    @State private var stripHeight: CGFloat = PlannedRouteStrip.occupiedHeight
    @State private var followUser = false
    @State private var userMovedCamera = false
    @State private var locateToken = 0
    @ObservedObject private var basemap = SkyBasemapCenter.shared

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let hasPlan = session.plannedRoute.count >= 2
            let collapsed = total / 3
            let strip = hasPlan ? stripHeight : 0
            let covered = collapsed + strip
            let fraction = min(0.72, Double(covered / max(total, 1)))
            ZStack(alignment: .bottom) {
                SkyTrackMap(
                    route: session.route,
                    planned: session.plannedRoute,
                    teammates: session.teammates,
                    kilometers: session.kilometerMarks,
                    showsUser: !session.simulating,
                    userCoordinate: session.userFix?.coordinate,
                    basemapMode: basemap.mode,
                    bottomInset: covered,
                    obscuredBottomFraction: fraction,
                    creditBottomInset: covered,
                    refitsOnChange: !followUser && !userMovedCamera,
                    suspendRefitAfterGesture: true,
                    followsUser: followUser,
                    locateToken: locateToken,
                    onUserCameraChange: {
                        followUser = false
                        userMovedCamera = true
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    locateButton
                        .padding(.leading, CGFloat(StartMapChrome.toolLeading))
                        .padding(.top, locateTop(total: total, covered: covered, safeTop: geo.safeAreaInsets.top))
                }

                if hasPlan {
                    PlannedRouteStrip(session: session)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: PlannedStripHeightKey.self, value: proxy.size.height)
                            }
                        }
                        .padding(.bottom, collapsed)
                }
                LiveDataSheet(
                    session: session,
                    confirmEnd: $confirmEnd,
                    expanded: $expanded,
                    dragTranslation: $dragTranslation,
                    totalHeight: total,
                    safeBottom: geo.safeAreaInsets.bottom,
                    reduceMotion: reduceMotion
                )
            }
            .onPreferenceChange(PlannedStripHeightKey.self) { height in
                guard height > 1, height < 360, abs(height - stripHeight) > 0.5 else { return }
                stripHeight = height
            }
        }
        .ignoresSafeArea()
    }

    private var locateButton: some View {
        let following = followUser && !userMovedCamera
        return Button {
            userMovedCamera = false
            followUser = true
            locateToken += 1
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(following ? SkyTheme.Color.onPrimary : SkyTheme.Color.onStarryGray)
                .frame(width: CGFloat(StartMapChrome.toolDiameter), height: CGFloat(StartMapChrome.toolDiameter))
                .background(following ? SkyTheme.Color.primary : SkyTheme.Color.starryGray, in: Circle())
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("回到当前位置")
    }

    /// Center of the map band above the sheet, kept below the status bar.
    private func locateTop(total: CGFloat, covered: CGFloat, safeTop: CGFloat) -> CGFloat {
        let diameter = CGFloat(StartMapChrome.toolDiameter)
        let visibleMid = max(0, total - covered) / 2
        return max(safeTop + 8, visibleMid - diameter / 2)
    }
}

private struct LiveDataSheet: View {
    @ObservedObject var session: LiveSession
    @Binding var confirmEnd: Bool
    @Binding var expanded: Bool
    @Binding var dragTranslation: CGFloat
    var totalHeight: CGFloat
    var safeBottom: CGFloat
    var reduceMotion: Bool

    private var sheetHeight: CGFloat {
        let collapsed = totalHeight / 3
        let expandedHeight = totalHeight * 2 / 3
        let base = expanded ? expandedHeight : collapsed
        return min(max(base - dragTranslation, collapsed), expandedHeight)
    }

    private var snap: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
                .contentShape(Rectangle())
                .gesture(drag)
                .layoutPriority(1)
            ZStack(alignment: .top) {
                detailScroll
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(expanded)
                    .accessibilityHidden(!expanded)
                if !expanded {
                    Text("上滑查看分段和曲线")
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.bottom, 4)
                        .contentShape(Rectangle())
                        .gesture(drag)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxHeight: .infinity)
            controls
                .layoutPriority(2)
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
        .padding(.bottom, max(safeBottom, 8))
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: sheetHeight, alignment: .top)
        .background {
            LiveSheetShape()
                .fill(SkyTheme.Color.grouped)
                .shadow(color: SkyTheme.Shadow.card.color.opacity(0.12), radius: 18, y: -6)
        }
    }

    private var sheetHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Capsule()
                .fill(SkyTheme.Color.tertiary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
                .onTapGesture { toggleSheet() }
                .accessibilityLabel(expanded ? "收起运动数据" : "展开运动数据")
                .accessibilityHint("上下拖动")
                .accessibilityAddTraits(.isButton)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("总时间")
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                    Text(Format.clock(session.elapsed))
                        .font(SkyTheme.Font.largeTitle)
                        .monospacedDigit()
                        .foregroundStyle(SkyTheme.Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 0) {
                    Text("总距离")
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                    Text(Format.kilometers(session.distanceMeters))
                        .font(SkyTheme.Font.largeTitle)
                        .monospacedDigit()
                        .foregroundStyle(SkyTheme.Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("公里")
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            if !session.statusText.isEmpty {
                Text(session.statusText)
                    .font(SkyTheme.Font.footnote)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .lineLimit(2)
            }
            HStack(alignment: .top, spacing: 8) {
                LiveMetricCell(title: "当前配速", value: Format.pace(session.paceSecPerKm), unit: "每公里")
                LiveMetricCell(
                    title: "当前心率",
                    value: Format.integer(session.heartRate),
                    unit: heartUnit,
                    heart: true
                )
                LiveMetricCell(title: "当前步频", value: Format.integer(session.cadence), unit: "步/分")
            }
        }
        .padding(.bottom, 4)
    }

    private var detailScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SkyTheme.Spacing.screenInset) {
                splitsCard
                heartCard
                cadenceCard
                elevationCard
                if !session.teammates.isEmpty {
                    Text(teammateNote)
                        .font(SkyTheme.Font.subheadline)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .liveCard()
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollDisabled(!expanded)
    }

    private var controls: some View {
        HStack(spacing: SkyTheme.Spacing.controlGap) {
            Button {
                session.paused ? session.resume() : session.pause()
            } label: {
                Label(session.paused ? "继续" : "暂停", systemImage: session.paused ? "play.fill" : "pause.fill")
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.primary)
                    .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.touchMin)
                    .background(SkyTheme.Color.card, in: Capsule())
                    .overlay {
                        Capsule().stroke(SkyTheme.Color.cardBorder, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            Button {
                confirmEnd = true
            } label: {
                Label("结束", systemImage: "stop.fill")
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: SkyTheme.Spacing.touchMin)
                    .background(SkyTheme.Color.danger, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragTranslation = value.translation.height
                }
            }
            .onEnded { value in
                let collapsed = totalHeight / 3
                let expandedHeight = totalHeight * 2 / 3
                let base = expanded ? expandedHeight : collapsed
                let predicted = min(max(base - value.predictedEndTranslation.height, collapsed), expandedHeight)
                withAnimation(snap) {
                    expanded = predicted > totalHeight / 2
                    dragTranslation = 0
                }
            }
    }

    private func toggleSheet() {
        withAnimation(snap) {
            expanded.toggle()
            dragTranslation = 0
        }
    }

    /// Phone has no heart-rate sensor. A dash stays a dash until this session measures one.
    private var heartUnavailable: Bool {
        guard !session.simulating, session.heartRate <= 0 else { return false }
        if session.heartSource == .none { return true }
        return session.heartSource == .watch && session.elapsed > 20
    }

    private var heartUnit: String {
        heartUnavailable ? "无来源" : "次/分"
    }

    private var displayedSplits: [KilometerSplit] {
        guard session.phase == .running else { return session.splits }
        return session.splits + [session.currentSplit]
    }

    private var teammateNote: String {
        let count = session.teammates.count
        let names = session.teammates.prefix(3).map(\.name).joined(separator: "、")
        if count > 3 {
            return "队友 \(names) 等 \(count) 人，本地模拟，位置在地图上"
        }
        return "队友 \(names)，本地模拟，位置在地图上"
    }

    private var splitsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LiveSectionTitle(title: "每公里分段", trailing: "配速 · 心率 · 步频 · 消耗")
            splitRow(index: "公里", pace: "配速", heart: "心率", cadence: "步频", energy: "千卡", header: true, partial: false)
            ForEach(displayedSplits) { split in
                splitRow(
                    index: "\(split.index)",
                    pace: Format.pace(split.paceSecPerKm),
                    heart: Format.integer(split.heartRate),
                    cadence: Format.integer(split.cadence),
                    energy: energyText(split.energyKilocalories),
                    header: false,
                    partial: split.partial
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(splitLabel(split))
            }
        }
        .liveCard()
    }

    private func splitRow(
        index: String,
        pace: String,
        heart: String,
        cadence: String,
        energy: String,
        header: Bool,
        partial: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(index)
                    .lineLimit(1)
                if partial {
                    Text("进行中")
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.primary)
                        .lineLimit(1)
                }
            }
            .frame(width: 56, alignment: .leading)
            Text(pace)
                .foregroundStyle(header ? SkyTheme.Color.secondary : SkyTheme.Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(heart)
                .frame(width: 48, alignment: .leading)
            Text(cadence)
                .frame(width: 48, alignment: .leading)
            Text(energy)
                .frame(width: 44, alignment: .trailing)
        }
        .font(header ? SkyTheme.Font.caption : SkyTheme.Font.footnote.weight(.semibold))
        .foregroundStyle(header ? SkyTheme.Color.secondary : SkyTheme.Color.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .monospacedDigit()
    }

    private func splitLabel(_ split: KilometerSplit) -> String {
        let state = split.partial ? "进行中" : "已完成"
        return "第 \(split.index) 公里，\(state)，配速 \(Format.pace(split.paceSecPerKm))，心率 \(Format.integer(split.heartRate))，步频 \(Format.integer(split.cadence))，活动消耗 \(energyText(split.energyKilocalories)) 千卡"
    }

    private var heartCard: some View {
        let samples = LiveSeriesPlot.samples(session.heartSeries)
        let average = TrainingSeriesMath.displayAverage(stored: 0, points: session.heartSeries)
        return VStack(alignment: .leading, spacing: 12) {
            LiveSectionTitle(title: "心率", trailing: "次/分")
            if samples.count >= 2 {
                statLine("当前 \(Format.integer(session.heartRate))", "平均 \(Format.integer(average))")
                LiveTimeChart(samples: samples)
                    .frame(height: 150)
                    .accessibilityHidden(true)
                LiveHeartZoneList(points: session.heartSeries)
            } else {
                Text(heartUnavailable ? "没有心率来源" : "心率还在采集")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, SkyTheme.Spacing.related)
            }
        }
        .liveCard()
        .accessibilityElement(children: .contain)
    }

    private var cadenceCard: some View {
        let samples = LiveSeriesPlot.samples(session.cadenceSeries)
        let average = TrainingSeriesMath.displayAverage(stored: 0, points: session.cadenceSeries)
        return VStack(alignment: .leading, spacing: 12) {
            LiveSectionTitle(title: "步频", trailing: "步/分")
            if samples.count >= 2 {
                statLine("当前 \(Format.integer(session.cadence))", "平均 \(Format.integer(average))")
                LiveTimeChart(samples: samples)
                    .frame(height: 150)
                    .accessibilityHidden(true)
            } else {
                Text("步频还在采集")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, SkyTheme.Spacing.related)
            }
        }
        .liveCard()
    }

    @ViewBuilder
    private var elevationCard: some View {
        if session.plannedRoute.count >= 2 {
            plannedElevationCard
        } else {
            trackedElevationCard
        }
    }

    /// Planned profile for the whole route, plus the climb and drop of the GPS track.
    private var plannedElevationCard: some View {
        let samples = PlannedRouteProgress.profileSamples(session.plannedRoute)
        let fix = PlannedRouteProgress.locate(athlete: session.route.last, on: session.plannedRoute)
        let climb = Int(session.elevationGainMeters.rounded())
        let drop = Int(session.elevationLossMeters.rounded())
        return VStack(alignment: .leading, spacing: 12) {
            LiveSectionTitle(title: "爬升下降", trailing: "米")
            Text("爬升 \(climb) 米 · 下降 \(drop) 米")
                .font(SkyTheme.Font.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(SkyTheme.Color.ink)
            if samples.count >= 2 {
                LiveElevationChart(
                    samples: samples,
                    markerKilometers: fix.progressedKilometers,
                    lineColor: SkyTheme.Color.chartNeutral
                )
                .frame(height: 150)
                .accessibilityHidden(true)
            }
        }
        .liveCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("爬升 \(climb) 米，下降 \(drop) 米，已跑 \(Format.kilometers(fix.progressedMeters)) 公里")
    }

    /// Free run. Elevation comes from the GPS track and stays behind the swipe-up sheet.
    private var trackedElevationCard: some View {
        let samples = RouteStats.profile(session.route)
        return VStack(alignment: .leading, spacing: 12) {
            LiveSectionTitle(title: "爬升下降", trailing: "米")
            if let summary = climbSummary {
                Text(summary)
                    .font(SkyTheme.Font.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(SkyTheme.Color.ink)
            }
            if showsElevation(samples) {
                LiveElevationChart(samples: samples)
                    .frame(height: 150)
                    .accessibilityHidden(true)
                Text("横轴公里 · 向上爬升 · 向下下降")
                    .font(SkyTheme.Font.caption)
                    .foregroundStyle(SkyTheme.Color.secondary)
            } else {
                Text(climbSummary == nil ? "海拔还在采集" : "曲线还不明显")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, SkyTheme.Spacing.related)
            }
        }
        .liveCard()
    }

    private var climbSummary: String? {
        let climb = Int(session.elevationGainMeters.rounded())
        let drop = Int(session.elevationLossMeters.rounded())
        guard climb >= 1 || drop >= 1 else { return nil }
        return "爬升 \(climb) 米 · 下降 \(drop) 米"
    }

    private func showsElevation(_ samples: [ElevationSample]) -> Bool {
        guard samples.count >= 2 else { return false }
        guard (samples.last?.distanceKilometers ?? 0) > 0.01 else { return false }
        let values = samples.map(\.changeMeters)
        guard let high = values.max(), let low = values.min() else { return false }
        return high - low > 0.4
    }

    private func statLine(_ leading: String, _ trailing: String) -> some View {
        HStack(spacing: 8) {
            Text(leading).frame(maxWidth: .infinity, alignment: .leading)
            Text(trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(SkyTheme.Font.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(SkyTheme.Color.ink)
    }

    private func energyText(_ kcal: Double) -> String {
        guard kcal.isFinite, kcal >= 0.5 else { return "—" }
        return String(Int(kcal.rounded()))
    }
}

private struct LiveMetricCell: View {
    var title: String
    var value: String
    var unit: String
    var heart: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if heart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SkyTheme.Color.danger)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(SkyTheme.Font.caption)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(value)
                .font(SkyTheme.Font.title2)
                .monospacedDigit()
                .foregroundStyle(SkyTheme.Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit)
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct LiveSectionTitle: View {
    var title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: SkyTheme.Spacing.related) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SkyTheme.Color.primary)
                .frame(width: 4, height: 16)
                .accessibilityHidden(true)
            Text(title)
                .font(SkyTheme.Font.title3)
                .foregroundStyle(SkyTheme.Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(SkyTheme.Font.caption)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct LiveSheetShape: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: SkyTheme.Radius.sheet,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: SkyTheme.Radius.sheet,
            style: .continuous
        ).path(in: rect)
    }
}

private struct LivePlotPoint: Identifiable {
    var id: Int
    var x: Double
    var y: Double
}

private enum LiveSeriesPlot {
    static func samples(_ points: [SeriesPoint], limit: Int = 80) -> [LivePlotPoint] {
        let ordered = unique(points)
        guard ordered.count >= 2 else { return [] }
        let step = max(1, ordered.count / max(limit, 2))
        var picked: [SeriesPoint] = []
        picked.reserveCapacity(min(ordered.count, limit + 1))
        for index in stride(from: 0, to: ordered.count, by: step) {
            picked.append(ordered[index])
        }
        if let last = ordered.last, picked.last?.second != last.second {
            picked.append(last)
        }
        return picked.enumerated().map { offset, point in
            LivePlotPoint(id: offset, x: point.second, y: point.value)
        }
    }

    private static func unique(_ points: [SeriesPoint]) -> [SeriesPoint] {
        var result: [SeriesPoint] = []
        var last = -Double.greatestFiniteMagnitude
        for point in points.sorted(by: { $0.second < $1.second }) {
            guard point.second.isFinite, point.value.isFinite, point.value > 0, point.second > last else { continue }
            result.append(point)
            last = point.second
        }
        return result
    }
}

private struct LiveTimeChart: View {
    var samples: [LivePlotPoint]

    var body: some View {
        Chart(samples) { sample in
            LineMark(
                x: .value("秒", sample.x),
                y: .value("值", sample.y)
            )
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .foregroundStyle(SkyTheme.Color.chartTrack)
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartXAxis { timeAxis }
        .chartYAxis { valueAxis }
    }

    private var xDomain: ClosedRange<Double> {
        let first = samples.first?.x ?? 0
        let last = samples.last?.x ?? 0
        return first...max(first + 1, last)
    }

    private var yDomain: ClosedRange<Double> {
        let values = samples.map(\.y)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let span = high - low
        let pad = span > 0 ? max(span * 0.18, 0.5) : max(abs(high) * 0.08, 1)
        return (low - pad)...(high + pad)
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(SkyTheme.Color.separator.opacity(0.7))
            AxisValueLabel {
                if let second = value.as(Double.self) {
                    Text(Format.clock(max(0, second)))
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                }
            }
        }
    }

    private var valueAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(SkyTheme.Color.separator.opacity(0.55))
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(String(Int(number.rounded())))
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                }
            }
        }
    }
}

private struct LiveElevationChart: View {
    var samples: [ElevationSample]
    var markerKilometers: Double? = nil
    var lineColor: Color = SkyTheme.Color.chartTrack

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("公里", sample.distanceKilometers),
                    yStart: .value("基准", 0),
                    yEnd: .value("升降", sample.changeMeters)
                )
                .foregroundStyle(lineColor.opacity(0.18))
                LineMark(
                    x: .value("公里", sample.distanceKilometers),
                    y: .value("升降", sample.changeMeters)
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(lineColor)
            }
            if let markerKilometers {
                let height = PlannedRouteProgress.changeMeters(at: markerKilometers, samples: samples)
                RuleMark(x: .value("进度", markerKilometers))
                    .foregroundStyle(SkyTheme.Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                PointMark(
                    x: .value("进度", markerKilometers),
                    y: .value("升降", height)
                )
                .foregroundStyle(SkyTheme.Color.primary)
                .symbolSize(36)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartXAxis { distanceAxis }
        .chartYAxis { meterAxis }
    }

    private var xDomain: ClosedRange<Double> {
        let last = max(samples.last?.distanceKilometers ?? 0, markerKilometers ?? 0)
        return 0...max(last, 0.05)
    }

    private var yDomain: ClosedRange<Double> {
        var values = samples.map(\.changeMeters)
        if let markerKilometers {
            values.append(PlannedRouteProgress.changeMeters(at: markerKilometers, samples: samples))
        }
        let low = min(0, values.min() ?? 0)
        let high = max(0, values.max() ?? 0)
        let span = high - low
        let pad = span > 0 ? max(span * 0.18, 1) : 1
        return (low - pad)...(high + pad)
    }

    private var distanceAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(SkyTheme.Color.separator.opacity(0.7))
            AxisValueLabel {
                if let kilometers = value.as(Double.self) {
                    Text(PlannedRouteProgress.axisLabel(distanceKilometers: kilometers))
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                }
            }
        }
    }

    private var meterAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(SkyTheme.Color.separator.opacity(0.55))
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(String(Int(number.rounded())))
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                }
            }
        }
    }
}

/// Same draft heart-rate cutoffs as `ZoneScale.heart` and the detail page.
/// The detail page names these five bands 有氧基础 through 冲刺能力.
private enum LiveHeartZones {
    struct Share: Identifiable {
        var name: String
        var range: String
        var seconds: Double
        var fraction: Double
        var id: String { name }
    }

    private static let bands: [(name: String, range: String, lower: Double, upper: Double)] = [
        ("区间 1", "<114", 0.001, 114),
        ("区间 2", "114–132", 114, 133),
        ("区间 3", "133–151", 133, 152),
        ("区间 4", "152–170", 152, 171),
        ("区间 5", "≥171", 171, .infinity)
    ]

    static func shares(_ points: [SeriesPoint]) -> [Share] {
        let ordered = points
            .filter { $0.second.isFinite && $0.value.isFinite && $0.value > 0 }
            .sorted { $0.second < $1.second }
        var seconds = Array(repeating: 0.0, count: bands.count)
        if ordered.count >= 2 {
            for index in 1..<ordered.count {
                let dt = ordered[index].second - ordered[index - 1].second
                guard dt > 0, dt <= TrainingSeriesMath.pauseGapSeconds else { continue }
                let value = ordered[index - 1].value
                guard let band = bands.firstIndex(where: { value >= $0.lower && value < $0.upper }) else { continue }
                seconds[band] += dt
            }
        }
        let total = seconds.reduce(0, +)
        return zip(bands, seconds).map { band, time in
            Share(
                name: band.name,
                range: band.range,
                seconds: time,
                fraction: total > 0 ? time / total : 0
            )
        }
    }
}

private struct LiveHeartZoneList: View {
    var points: [SeriesPoint]

    private var shares: [LiveHeartZones.Share] {
        LiveHeartZones.shares(points)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("心率区间")
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.ink)
            ForEach(shares) { share in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(share.name)
                            .frame(width: 48, alignment: .leading)
                        Text(share.range)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.clock(share.seconds))
                            .monospacedDigit()
                        Text(percentText(share.fraction))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                    .font(SkyTheme.Font.caption)
                    .foregroundStyle(SkyTheme.Color.ink)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(SkyTheme.Color.separator.opacity(0.45))
                            Capsule()
                                .fill(SkyTheme.Color.primary)
                                .frame(width: max(0, geo.size.width * share.fraction))
                        }
                    }
                    .frame(height: 8)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 4)
    }

    private func percentText(_ fraction: Double) -> String {
        guard fraction > 0 else { return "0%" }
        return String(format: "%.1f%%", fraction * 100)
    }
}

private extension View {
    func liveCard() -> some View {
        padding(SkyTheme.Spacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SkyTheme.Color.card,
                in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous)
                    .stroke(SkyTheme.Color.cardBorder, lineWidth: 1)
            }
    }
}

/// Full planned elevation profile, pinned to the bottom of the visible map.
/// The marker and the remaining distance use `PlannedRouteProgress.locate`.
private struct PlannedRouteStrip: View {
    /// First-frame height before layout reports the real one. Chart plus the distance row.
    static let occupiedHeight: CGFloat = 148

    @ObservedObject var session: LiveSession

    private var samples: [ElevationSample] {
        PlannedRouteProgress.profileSamples(session.plannedRoute)
    }

    private var fix: PlannedRouteProgress.Fix {
        PlannedRouteProgress.locate(athlete: session.route.last, on: session.plannedRoute)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: SkyTheme.Spacing.related) {
                distanceColumn("已跑距离", meters: fix.progressedMeters)
                distanceColumn("路线剩余距离", meters: fix.remainingMeters)
            }
            LiveElevationChart(
                samples: samples,
                markerKilometers: fix.progressedKilometers,
                lineColor: SkyTheme.Color.chartNeutral
            )
            .frame(height: 88)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(SkyTheme.Color.card.opacity(0.96))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("已跑距离 \(Format.kilometers(fix.progressedMeters)) 公里，路线剩余距离 \(Format.kilometers(fix.remainingMeters)) 公里")
    }

    private func distanceColumn(_ title: String, meters: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(Format.kilometers(meters))
                    .font(SkyTheme.Font.title3)
                    .monospacedDigit()
                    .foregroundStyle(SkyTheme.Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("公里")
                    .font(SkyTheme.Font.caption)
                    .foregroundStyle(SkyTheme.Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlannedStripHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// The live screen is pushed over the start map. Ending the workout is the way back.
/// SwiftUI can leave the interactive pop enabled after the navigation bar is hidden, so this turns it off.
private struct LivePopLock: UIViewRepresentable {
    func makeUIView(context: Context) -> LivePopLockView {
        let view = LivePopLockView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: LivePopLockView, context: Context) {
        view.lock()
    }
}

private final class LivePopLockView: UIView {
    private weak var pop: UIGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            unlock()
            return
        }
        lock()
        DispatchQueue.main.async { [weak self] in
            self?.lock()
        }
    }

    func lock() {
        guard window != nil, let gesture = enclosingNavigationController()?.interactivePopGestureRecognizer else { return }
        pop = gesture
        gesture.isEnabled = false
    }

    private func unlock() {
        // The next screen manages its own gesture. Leaving this off would stick for 组队.
        pop?.isEnabled = true
        pop = nil
    }

    private func enclosingNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController {
                return navigation
            }
            responder = current.next
        }
        return nil
    }
}

struct LayoutEditor: View {
    @EnvironmentObject private var app: PhoneAppState
    @Environment(\.dismiss) private var dismiss
    @State private var order: [LiveBlock] = []

    var body: some View {
        List {
            Section {
                ForEach(order) { block in
                    Text(block.title)
                        .font(.system(size: 17, design: .rounded))
                        .foregroundStyle(Color.omniInk)
                        .listRowBackground(Color.white.opacity(0.4))
                }
                .onMove { from, to in
                    order.move(fromOffsets: from, toOffset: to)
                }
            } header: {
                Text("拖动调整顺序")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
                    .textCase(nil)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background(CanvasBackground())
        .navigationTitle("调整展示位置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .tint(Color.omniCobalt)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    app.setMetricOrder(order)
                    dismiss()
                }
                .font(.system(size: 17, weight: .bold, design: .rounded))
            }
        }
        .onAppear {
            if order.isEmpty {
                order = app.metricOrder
            }
        }
    }
}
