import Charts
import SwiftUI
import UIKit

/// Record detail. Map fills the first screen; the white sheet holds the primary
/// metrics. Splits and charts sit below the fold. Series that were never stored
/// stay empty instead of drawing stand-in data.
struct WorkoutDetailView: View {
    @EnvironmentObject private var app: PhoneAppState
    @Environment(\.dismiss) private var dismiss
    var workoutID: UUID

    @State private var fitToken = 0
    @State private var mapStyle = DetailMapStyle.stored
    @State private var showShare = false
    @State private var showStyles = false
    @State private var exporting = false
    @State private var saveMessage: String?
    @State private var viewport = CGSize.zero
    @State private var topInset: CGFloat = 0

    private var workout: WorkoutRecord? {
        app.workouts.first { $0.id == workoutID }
    }

    var body: some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            ScrollView {
                if let workout {
                    detail(workout, viewportHeight: geo.size.height, topInset: top)
                } else {
                    missing(viewportHeight: geo.size.height)
                }
            }
            .scrollIndicators(.hidden)
            .background(SkyTheme.Color.grouped)
            .onAppear {
                viewport = geo.size
                topInset = top
            }
            .onChange(of: geo.size) { _, size in
                viewport = size
            }
            .onChange(of: top) { _, inset in
                topInset = inset
            }
        }
        .background(SkyTheme.Color.grouped)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task(id: workoutID) {
            await loadContextIfNeeded()
        }
        .sheet(isPresented: $showShare) {
            shareSheet
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
                .presentationBackground(SkyTheme.Color.background)
        }
        .sheet(isPresented: $showStyles) {
            styleSheet
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
                .presentationBackground(SkyTheme.Color.background)
        }
        .alert(saveMessage ?? "", isPresented: saveAlertPresented) {
            Button("好", role: .cancel) {}
        }
        .overlay {
            if exporting {
                ProgressView()
                    .controlSize(.large)
                    .tint(SkyTheme.Color.primary)
                    .padding(SkyTheme.Spacing.section)
                    .background(SkyTheme.Color.card, in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
                    .accessibilityLabel("正在生成图片")
            }
        }
        .background {
            InteractivePopGestureEnabler()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private var saveAlertPresented: Binding<Bool> {
        Binding(
            get: { saveMessage != nil },
            set: { if !$0 { saveMessage = nil } }
        )
    }

    private func detail(_ workout: WorkoutRecord, viewportHeight: CGFloat, topInset: CGFloat) -> some View {
        let mapHeight = viewportHeight * 0.56 + topInset
        return VStack(spacing: 0) {
            mapHeader(workout, height: mapHeight, topInset: topInset)
                .padding(.top, -topInset)
            recordColumn(workout, showsCharts: true, overlapsMap: true)
        }
    }

    private func recordColumn(_ workout: WorkoutRecord, showsCharts: Bool, overlapsMap: Bool) -> some View {
        VStack(spacing: 0) {
            summarySheet(workout, overlapsMap: overlapsMap)
            if showsCharts {
                charts(workout)
            }
        }
    }

    private func charts(_ workout: WorkoutRecord) -> some View {
        VStack(spacing: SkyTheme.Spacing.section) {
            DetailSplitsCard(workout: workout)
            paceCard(workout)
            heartCard(workout)
            seriesCard(
                title: "步频（步/分）",
                points: WorkoutDetailMath.positive(workout.cadenceSeries),
                average: TrainingSeriesMath.trainingAverage(workout.cadenceSeries),
                extremeTitle: "最大",
                digits: 0
            )
            seriesCard(
                title: "步幅（米/步）",
                points: WorkoutDetailMath.positive(workout.stride),
                average: TrainingSeriesMath.spanAverage(workout.stride),
                extremeTitle: "最大",
                digits: 2
            )
            seriesCard(
                title: "功率（瓦）",
                points: WorkoutDetailMath.positive(workout.power),
                average: WorkoutDetailMath.mean(workout.power),
                extremeTitle: "最大",
                digits: 0
            )
            seriesCard(
                title: "垂直振幅（毫米）",
                points: WorkoutDetailMath.positive(workout.verticalOscillation),
                average: WorkoutDetailMath.mean(workout.verticalOscillation),
                extremeTitle: "最大",
                digits: 0
            )
            seriesCard(
                title: "触地时间（毫秒）",
                points: WorkoutDetailMath.positive(workout.groundContact),
                average: WorkoutDetailMath.mean(workout.groundContact),
                extremeTitle: "最大",
                digits: 0
            )
            elevationCard(workout)
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
        .padding(.top, SkyTheme.Spacing.section)
        .padding(.bottom, SkyTheme.Spacing.section + SkyTheme.Spacing.related)
        .frame(maxWidth: .infinity)
        .background(SkyTheme.Color.grouped)
    }

    private func mapHeader(_ workout: WorkoutRecord, height: CGFloat, topInset: CGFloat) -> some View {
        let band = obscuredMapBand(height: height, topInset: topInset)
        return ZStack(alignment: .top) {
            RouteMap(
                route: workout.route,
                cornerRadius: 0,
                routeColor: SkyTheme.Color.primary,
                routeLineWidth: 5,
                obscuredBottomFraction: band.bottom,
                obscuredTopFraction: band.top,
                showsEndpoints: workout.route.count >= 2,
                hidesMapControls: true,
                fitToken: fitToken,
                style: mapStyle.mapStyle
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
            if workout.route.count < 2 {
                Text("这次没有轨迹")
                    .font(SkyTheme.Font.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(SkyTheme.Color.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SkyTheme.Color.card.opacity(0.94), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, SkyTheme.Radius.sheet + 12)
            }

            HStack {
                mapButton(system: "chevron.left", label: "返回") {
                    dismiss()
                }
                Spacer(minLength: SkyTheme.Spacing.controlGap)
                HStack(spacing: SkyTheme.Spacing.controlGap) {
                    mapButton(system: "square.and.arrow.up", label: "分享") {
                        showShare = true
                    }
                    .disabled(exporting)
                    mapButton(system: "square.3.layers.3d", label: "地图样式") {
                        showStyles = true
                    }
                    if workout.route.count >= 2 {
                        mapButton(system: "location.viewfinder", label: "回到轨迹") {
                            fitToken += 1
                        }
                    }
                }
            }
            .padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.top, topInset + SkyTheme.Spacing.related)
        }
    }

    /// Clear band for the detail camera. Top is the toolbar's bottom edge
    /// (`topInset + related + touchMin`, matching the buttons above). Bottom is the
    /// summary card overlap (`Radius.sheet`).
    private func obscuredMapBand(height: CGFloat, topInset: CGFloat) -> (top: Double, bottom: Double) {
        guard height > 1 else { return (0, 0) }
        let toolbarBottom = topInset + SkyTheme.Spacing.related + SkyTheme.Spacing.touchMin
        return (
            max(0, Double(toolbarBottom / height)),
            max(0, Double(SkyTheme.Radius.sheet / height))
        )
    }

    private func mapButton(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SkyTheme.Color.ink)
                .frame(width: SkyTheme.Spacing.touchMin, height: SkyTheme.Spacing.touchMin)
                .background(SkyTheme.Color.card, in: Circle())
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func metricPair(_ leading: DetailMetric, _ trailing: DetailMetric) -> some View {
        HStack(alignment: .top, spacing: 12) {
            leading
            trailing
        }
    }

    private func summarySheet(_ workout: WorkoutRecord, overlapsMap: Bool) -> some View {
        VStack(alignment: .leading, spacing: SkyTheme.Spacing.related) {
            VStack(alignment: .leading, spacing: SkyTheme.Spacing.related) {
                HStack(alignment: .center, spacing: 12) {
                    profileAvatar
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = accountName {
                            Text(name)
                                .font(SkyTheme.Font.subheadline)
                                .foregroundStyle(SkyTheme.Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Text(workout.sport.title)
                            .font(SkyTheme.Font.title3)
                            .foregroundStyle(SkyTheme.Color.ink)
                            .lineLimit(1)
                        Text(Format.dateSpan(from: workout.start, to: workout.end))
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(SkyTheme.Color.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: SkyTheme.Spacing.related)
                    if let badge = originBadge(workout) {
                        Text(badge)
                            .font(SkyTheme.Font.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(SkyTheme.Color.primary)
                    }
                }
                weatherRow(workout)
                placeRow(workout)
            }

            VStack(spacing: 4) {
                metricPair(
                    DetailMetric(label: "训练时间", value: Format.clock(workout.trainingDuration), color: SkyTheme.Color.Metric.duration),
                    DetailMetric(label: "经过时间", value: Format.clock(workout.elapsedDuration), color: SkyTheme.Color.Metric.duration)
                )
                metricPair(
                    DetailMetric(label: "距离", value: distanceText(workout), unit: "公里", color: SkyTheme.Color.Metric.distance),
                    DetailMetric(label: "配速", value: Format.pace(workout.averagePaceSecPerKm), unit: "/公里", color: SkyTheme.Color.Metric.pace)
                )
                metricPair(
                    DetailMetric(label: "心率", value: Format.integer(workout.resolvedAverageHeartRate), unit: "次/分", color: SkyTheme.Color.Metric.heartRate),
                    DetailMetric(label: "步频", value: Format.integer(workout.resolvedAverageCadence), unit: "步/分", color: SkyTheme.Color.Metric.pace)
                )
                metricPair(
                    DetailMetric(label: "爬升", value: climbText(workout), unit: "米", color: SkyTheme.Color.Metric.elevation),
                    DetailMetric(label: "步幅", value: strideText(workout.averageStrideMeters), unit: "米", color: SkyTheme.Color.Metric.pace)
                )
                metricPair(
                    DetailMetric(label: "负荷", value: countText(Double(workout.sessionLoad)), color: SkyTheme.Color.Metric.load),
                    DetailMetric(label: "能量", value: countText(workout.energyKilocalories), unit: "千卡", color: SkyTheme.Color.Metric.energy)
                )
            }
            .padding(.horizontal, SkyTheme.Spacing.cardPadding)
            .padding(.vertical, 10)
            .background(SkyTheme.Color.grouped, in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous))
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
        .padding(.top, SkyTheme.Spacing.screenInset)
        .padding(.bottom, SkyTheme.Spacing.related)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: SkyTheme.Radius.sheet,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: SkyTheme.Radius.sheet,
                style: .continuous
            )
            .fill(SkyTheme.Color.background)
            .shadow(color: Color.black.opacity(0.08), radius: 12, y: -2)
        }
        .padding(.top, overlapsMap ? -SkyTheme.Radius.sheet : 0)
    }

    /// Same face as the home tab-bar avatar. Logged out keeps that scenic placeholder and no name.
    @ViewBuilder
    private var profileAvatar: some View {
        let diameter = SkyTheme.Spacing.touchMin
        if app.isLoggedIn {
            AccountAvatarFace(
                name: app.account?.name ?? "",
                image: app.accountAvatar,
                diameter: diameter
            )
        } else {
            ScenicAvatar()
                .frame(width: diameter, height: diameter)
        }
    }

    private var accountName: String? {
        guard app.isLoggedIn else { return nil }
        let name = app.account?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private func weatherRow(_ workout: WorkoutRecord) -> some View {
        let conditions = workout.conditions
        return HStack(spacing: 14) {
            contextItem(
                system: "thermometer.medium",
                text: Format.celsius(conditions?.temperatureCelsius),
                label: "气温"
            )
            contextItem(
                system: "humidity.fill",
                text: Format.humidity(conditions?.relativeHumidityPercent),
                label: "湿度"
            )
            contextItem(
                system: "aqi.medium",
                text: Format.airQuality(index: conditions?.airQualityIndex, grade: conditions?.airQualityGrade),
                label: "空气质量"
            )
            Spacer(minLength: 0)
        }
    }

    private func placeRow(_ workout: WorkoutRecord) -> some View {
        let line = Format.startPoint(
            name: workout.startPlace?.name,
            latitude: workout.startCoordinate?.latitude,
            longitude: workout.startCoordinate?.longitude
        )
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(line)
                .font(SkyTheme.Font.footnote)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(SkyTheme.Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("起点 \(line)")
    }

    private func contextItem(system: String, text: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(SkyTheme.Font.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(SkyTheme.Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(text)")
    }

    private func loadContextIfNeeded() async {
        guard let workout else { return }
        let workoutID = workout.id
        let patch = await WorkoutContext.load(workout)
        app.storeWorkoutContext(
            workoutID: workoutID,
            conditions: patch.conditions,
            startPlace: patch.startPlace
        )
    }

    private func originBadge(_ workout: WorkoutRecord) -> String? {
        switch workout.origin {
        case .apple:
            return nil
        case .sample:
            return "示例数据"
        case .simulated:
            return "本地模拟"
        }
    }

    private func distanceText(_ workout: WorkoutRecord) -> String {
        guard workout.distanceMeters > 1 else { return "—" }
        return Format.kilometers(workout.distanceMeters)
    }

    private func countText(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        return String(Int(value.rounded()))
    }

    private func strideText(_ meters: Double) -> String {
        guard meters > 0 else { return "—" }
        return String(format: "%.2f", meters)
    }

    private func climbText(_ workout: WorkoutRecord) -> String {
        let profile = WorkoutDetailMath.elevationProfile(workout)
        let meters = WorkoutDetailMath.displayedClimb(workout, profile: profile)
        guard profile.points.count >= 2 || meters > 0 else { return "—" }
        return String(Int(meters.rounded()))
    }

    private func paceCard(_ workout: WorkoutRecord) -> some View {
        let points = WorkoutDetailMath.runningPace(workout.paceSeries)
        return ZoneSeriesCard(
            title: "配速区间",
            points: points,
            leadingValue: Format.pace(workout.averagePaceSecPerKm),
            leadingLabel: "平均",
            trailingValue: Format.pace(WorkoutDetailMath.extreme(points, fastest: true) ?? 0),
            trailingLabel: "最快",
            accent: SkyTheme.Color.Metric.pace,
            bands: WorkoutDetailMath.paceBands,
            invert: true
        )
    }

    private func heartCard(_ workout: WorkoutRecord) -> some View {
        let points = WorkoutDetailMath.positive(workout.heartRate)
        return ZoneSeriesCard(
            title: "心率区间",
            points: points,
            leadingValue: Format.integer(workout.resolvedAverageHeartRate),
            leadingUnit: "次/分",
            leadingLabel: "平均",
            trailingValue: Format.integer(WorkoutDetailMath.extreme(points, fastest: false) ?? 0),
            trailingUnit: "次/分",
            trailingLabel: "最大",
            accent: SkyTheme.Color.Metric.heartRate,
            bands: WorkoutDetailMath.heartBands,
            invert: false,
            paintCrossings: true
        )
    }

    private func seriesCard(
        title: String,
        points: [SeriesPoint],
        average: Double?,
        extremeTitle: String,
        digits: Int
    ) -> some View {
        DetailChartCard(
            title: title,
            points: points,
            leading: stat("平均", WorkoutDetailMath.format(average, digits: digits)),
            trailing: stat(extremeTitle, WorkoutDetailMath.format(WorkoutDetailMath.extreme(points, fastest: false), digits: digits)),
            kind: .line,
            valueDigits: digits
        )
    }

    private func elevationCard(_ workout: WorkoutRecord) -> some View {
        let profile = WorkoutDetailMath.elevationProfile(workout)
        let climb = WorkoutDetailMath.displayedClimb(workout, profile: profile)
        let finite = profile.points.map(\.value).filter(\.isFinite)
        let hasLine = WorkoutDetailMath.plotSamples(profile.points).count >= 2
        let climbText = hasLine || climb > 0 ? String(Int(climb.rounded())) : "—"
        let peakText = finite.max().map { String(Int($0.rounded())) } ?? "—"
        return ElevationChartCard(points: profile.points, climb: climbText, peak: peakText)
    }

    private func stat(_ title: String, _ value: String) -> String? {
        guard value != "—" else { return nil }
        return "\(title) \(value)"
    }

    private var shareSheet: some View {
        VStack(spacing: 0) {
            shareChoice(title: "首屏", subtitle: "地图和这次的主要数据", kind: .screen)
            shareChoice(title: "全数据长图", subtitle: "地图、主要数据，以及下面的分段和图表", kind: .full)
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
        .padding(.top, SkyTheme.Spacing.related)
        .padding(.bottom, SkyTheme.Spacing.screenInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SkyTheme.Color.background)
    }

    private func shareChoice(title: String, subtitle: String, kind: DetailShareKind) -> some View {
        Button {
            Task { await export(kind) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.ink)
                Text(subtitle)
                    .font(SkyTheme.Font.footnote)
                    .foregroundStyle(SkyTheme.Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: SkyTheme.Spacing.listRowMin)
        }
        .buttonStyle(.plain)
        .disabled(exporting)
        .accessibilityLabel(title)
    }

    private var styleSheet: some View {
        VStack(spacing: 0) {
            ForEach(DetailMapStyle.allCases) { style in
                Button {
                    mapStyle = style
                    style.save()
                } label: {
                    HStack(spacing: SkyTheme.Spacing.related) {
                        Text(style.title)
                            .font(SkyTheme.Font.headline)
                            .foregroundStyle(SkyTheme.Color.ink)
                        Spacer(minLength: SkyTheme.Spacing.related)
                        if mapStyle == style {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(SkyTheme.Color.primary)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: SkyTheme.Spacing.listRowMin)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mapStyle == style ? "\(style.title)，已选择" : style.title)
            }
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
        .padding(.top, SkyTheme.Spacing.related)
        .padding(.bottom, SkyTheme.Spacing.screenInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SkyTheme.Color.background)
    }

    @MainActor
    private func export(_ kind: DetailShareKind) async {
        guard let workout, !exporting else { return }
        exporting = true
        showShare = false
        defer { exporting = false }
        let width = viewport.width > 1 ? viewport.width : 390
        let mapHeight = max(220, (viewport.height > 1 ? viewport.height : 844) * 0.56 + topInset)
        let summary = DetailShareImage.render(
            summarySheet(workout, overlapsMap: false),
            width: width
        )
        let chartImage = kind == .full
            ? DetailShareImage.render(charts(workout), width: width)
            : nil
        guard let summary else {
            saveMessage = "图片没有生成"
            return
        }
        if kind == .full, chartImage == nil {
            saveMessage = "图片没有生成"
            return
        }
        guard let map = await DetailShareImage.mapImage(
            route: workout.route,
            style: mapStyle,
            size: CGSize(width: width, height: mapHeight)
        ) else {
            saveMessage = "图片没有生成"
            return
        }
        let image = DetailShareImage.assemble(
            map: map,
            summary: summary,
            charts: chartImage,
            overlap: SkyTheme.Radius.sheet
        )
        switch await DetailPhotoLibrary.save(image) {
        case .saved:
            saveMessage = "已保存到相册"
        case .denied:
            saveMessage = "没有相册权限"
        case .failed:
            saveMessage = "图片没有保存"
        }
    }

    private func missing(viewportHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                mapButton(system: "chevron.left", label: "返回") {
                    dismiss()
                }
                Spacer()
            }
            .padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.top, SkyTheme.Spacing.related)
            Spacer()
            Text("找不到这次训练")
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: viewportHeight)
    }
}

/// Label above the figure. Number and unit share weight and the metric color.
/// An em dash stays secondary and drops the unit.
private struct DetailMetric: View {
    var label: String
    var value: String
    var unit: String? = nil
    var color: Color

    private var missing: Bool { value == "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(SkyTheme.Font.caption)
                .fontWeight(.medium)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                if let unit, !missing {
                    Text(unit)
                }
            }
            .font(SkyTheme.Font.title3)
            .fontWeight(.bold)
            .foregroundStyle(missing ? SkyTheme.Color.secondary : color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Figure with the unit beside it, and the caption underneath. Used by the zone and elevation cards.
private struct MetricHeadline: View {
    var value: String
    var unit: String? = nil
    var label: String
    var color: Color

    private var missing: Bool { value == "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                if let unit, !missing {
                    Text(unit)
                }
            }
            .font(SkyTheme.Font.title2)
            .fontWeight(.bold)
            .foregroundStyle(missing ? SkyTheme.Color.secondary : color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(label)
                .font(SkyTheme.Font.caption)
                .fontWeight(.medium)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private enum PaceTrend {
    case faster
    case slower

    var symbol: String {
        switch self {
        case .faster: return "arrow.up"
        case .slower: return "arrow.down"
        }
    }

    var color: Color {
        switch self {
        case .faster: return SkyTheme.Color.Metric.elevation
        case .slower: return SkyTheme.Color.Metric.heartRate
        }
    }

    var label: String {
        switch self {
        case .faster: return "更快"
        case .slower: return "更慢"
        }
    }
}

/// Pace arrows compare the rounded seconds already shown in the table.
/// Fastest and slowest tags apply only to full kilometers, and only when they differ.
private struct SplitPaceMarks {
    var trend: [Int: PaceTrend] = [:]
    var tag: [Int: String] = [:]

    static func make(splits: [KilometerSplit]) -> SplitPaceMarks {
        var marks = SplitPaceMarks()
        for index in splits.indices where index > 0 {
            guard let current = displayedSecond(splits[index]),
                  let previous = displayedSecond(splits[index - 1]),
                  current != previous else { continue }
            marks.trend[splits[index].index] = current < previous ? .faster : .slower
        }
        let full = splits.compactMap { split -> (index: Int, second: Int)? in
            guard !split.partial, let second = displayedSecond(split) else { return nil }
            return (split.index, second)
        }
        guard full.count >= 2 else { return marks }
        guard let fastest = full.map(\.second).min(),
              let slowest = full.map(\.second).max(),
              fastest != slowest else { return marks }
        for item in full {
            if item.second == fastest {
                marks.tag[item.index] = "最快"
            } else if item.second == slowest {
                marks.tag[item.index] = "最慢"
            }
        }
        return marks
    }

    private static func displayedSecond(_ split: KilometerSplit) -> Int? {
        let pace = split.paceSecPerKm
        guard pace.isFinite, pace > 0, pace < 3_600 else { return nil }
        return Int(pace.rounded())
    }
}

private struct DetailSplitsCard: View {
    var workout: WorkoutRecord

    /// One line for the header and every body row. The fastest and slowest
    /// labels sit in a fixed slot to the left of the index, so they do not
    /// change the row height or shift the numbers.
    private static let rowHeight: CGFloat = 36
    private static let columnGap: CGFloat = 2
    private static let separatorBlock: CGFloat = 9
    private static let tagWidth: CGFloat = 30
    private static let paceColumn = 3

    var body: some View {
        let splits = workout.resolvedSplits
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionTitle(title: "分段信息", trailing: splits.isEmpty ? nil : "每公里")
            if splits.isEmpty {
                Text("这次没有每公里数据")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, SkyTheme.Spacing.related)
            } else {
                table(splits)
            }
        }
        .detailCard()
    }

    private func table(_ splits: [KilometerSplit]) -> some View {
        let marks = SplitPaceMarks.make(splits: splits)
        let rowCount = CGFloat(splits.count + 2)
        return GeometryReader { geo in
            let widths = Self.columnWidths(in: geo.size.width)
            VStack(spacing: 0) {
                splitRow(
                    ["圈数", "时间", "距离", "配速", "心率", "步频"],
                    widths: widths,
                    header: true
                )
                ForEach(splits) { split in
                    splitRow(
                        [
                            "\(split.index)",
                            split.listedTimeText,
                            split.listedDistanceText,
                            Format.pace(split.paceSecPerKm),
                            Format.integer(split.heartRate),
                            Format.integer(split.cadence)
                        ],
                        widths: widths,
                        trend: marks.trend[split.index],
                        tag: marks.tag[split.index]
                    )
                }
                Rectangle()
                    .fill(SkyTheme.Color.separator)
                    .frame(height: 1)
                    .padding(.vertical, 4)
                splitRow(
                    [
                        "总计",
                        Format.clock(workout.trainingDuration),
                        Format.kilometers(workout.distanceMeters),
                        Format.pace(workout.averagePaceSecPerKm),
                        Format.integer(workout.resolvedAverageHeartRate),
                        Format.integer(workout.resolvedAverageCadence)
                    ],
                    widths: widths
                )
            }
        }
        .frame(height: rowCount * Self.rowHeight + Self.separatorBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Index keeps a fixed slot for 最快 / 最慢. Heart rate and cadence fit three
    /// digits. Whatever remains is split between time and pace.
    private static func columnWidths(in total: CGFloat) -> [CGFloat] {
        let gaps = columnGap * 5
        let index = min(CGFloat(68), max(CGFloat(64), total * 0.20))
        let distance = min(CGFloat(48), max(CGFloat(40), total * 0.14))
        let heart = min(CGFloat(34), max(CGFloat(28), total * 0.10))
        let cadence = heart
        let fixed = index + distance + heart + cadence + gaps
        let free = max(0, total - fixed)
        let time = (free * 0.44 * 100).rounded() / 100
        let pace = max(0, free - time)
        return [index, time, distance, pace, heart, cadence]
    }

    private func splitRow(
        _ cells: [String],
        widths: [CGFloat],
        header: Bool = false,
        trend: PaceTrend? = nil,
        tag: String? = nil
    ) -> some View {
        HStack(spacing: Self.columnGap) {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                splitCell(
                    cell,
                    column: column,
                    width: widths.indices.contains(column) ? widths[column] : 0,
                    header: header,
                    trend: trend,
                    tag: tag
                )
            }
        }
        .frame(height: Self.rowHeight)
        .background { rowWash(header ? nil : tag) }
        .accessibilityElement(children: .combine)
    }

    /// Pale frost on the fastest and slowest full kilometers. The wash sits on
    /// top of a thin material so the row stays translucent on the white card.
    @ViewBuilder
    private func rowWash(_ tag: String?) -> some View {
        if let wash = washColor(tag) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(wash)
                }
                .accessibilityHidden(true)
        }
    }

    private func washColor(_ tag: String?) -> Color? {
        switch tag {
        case "最快":
            return SkyTheme.Color.success.opacity(0.28)
        case "最慢":
            return SkyTheme.Color.danger.opacity(0.20)
        default:
            return nil
        }
    }

    @ViewBuilder
    private func splitCell(
        _ cell: String,
        column: Int,
        width: CGFloat,
        header: Bool,
        trend: PaceTrend?,
        tag: String?
    ) -> some View {
        let text = Text(cell)
            .font(SkyTheme.Font.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(color(header: header, column: column, text: cell))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        if column == 0 {
            HStack(spacing: 2) {
                Text(header ? "" : (tag ?? ""))
                    .font(SkyTheme.Font.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: Self.tagWidth, alignment: .leading)
                text
            }
            .frame(width: width, height: Self.rowHeight, alignment: .leading)
        } else if column == Self.paceColumn, let trend, !header {
            HStack(alignment: .center, spacing: 2) {
                text
                Image(systemName: trend.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(trend.color)
                    .accessibilityLabel(trend.label)
            }
            .frame(width: width, height: Self.rowHeight, alignment: .leading)
        } else {
            text
                .frame(width: width, height: Self.rowHeight, alignment: .leading)
        }
    }

    private func color(header: Bool, column: Int, text: String) -> Color {
        if header || text == "—" {
            return SkyTheme.Color.secondary
        }
        if column == Self.paceColumn { return SkyTheme.Color.primary }
        return SkyTheme.Color.ink
    }
}

private struct ZoneSeriesCard: View {
    var title: String
    var points: [SeriesPoint]
    var leadingValue: String
    var leadingUnit: String? = nil
    var leadingLabel: String
    var trailingValue: String
    var trailingUnit: String? = nil
    var trailingLabel: String
    var accent: Color
    var bands: [ZoneBand]
    var invert: Bool
    /// Heart rate samples are sparse, so a straight stroke can cross several
    /// bands. Split that stroke on the cutoffs. Pace stays on the sample boundary.
    var paintCrossings: Bool = false

    private var samples: [ChartSample] {
        WorkoutDetailMath.plotSamples(points)
    }

    private var showsChart: Bool { samples.count >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionTitle(title: title)
            if leadingValue != "—" || trailingValue != "—" {
                HStack(alignment: .top, spacing: 8) {
                    MetricHeadline(value: leadingValue, unit: leadingUnit, label: leadingLabel, color: accent)
                    MetricHeadline(value: trailingValue, unit: trailingUnit, label: trailingLabel, color: accent)
                }
            }
            if showsChart {
                chart
                    .frame(height: 168)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title)，\(leadingLabel) \(leadingValue)，\(trailingLabel) \(trailingValue)")
                zoneRows
            } else {
                Text("这次没有采集到")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, SkyTheme.Spacing.related)
            }
        }
        .detailCard()
    }

    private var zoneRows: some View {
        let shares = WorkoutDetailMath.shares(points: points, bands: bands)
        return VStack(spacing: SkyTheme.Spacing.related) {
            ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                ZoneShareRow(
                    name: share.name,
                    range: share.range,
                    fraction: share.fraction,
                    color: zoneColor(index)
                )
            }
        }
    }

    private func zoneColor(_ index: Int) -> Color {
        let colors = SkyTheme.Color.Zone.ordered
        guard colors.indices.contains(index) else { return SkyTheme.Color.Zone.base }
        return colors[index]
    }

    private func color(for name: String) -> Color {
        let index = bands.firstIndex { $0.name == name } ?? 0
        return zoneColor(index)
    }

    private var chart: some View {
        let segments = paintCrossings
            ? WorkoutDetailMath.boundaryZoneSegments(samples: samples, bands: bands)
            : WorkoutDetailMath.zoneSegments(samples: samples, bands: bands)
        let domain = plottedDomain
        return Chart {
            ForEach(segments) { segment in
                ForEach(segment.samples) { sample in
                    LineMark(
                        x: .value("秒", sample.second),
                        y: .value("值", invert ? -sample.value : sample.value),
                        series: .value("段", segment.id)
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(color(for: segment.name))
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: domain)
        .chartXAxis { timeAxis }
        .chartYAxis { valueAxis }
        .chartLegend(.hidden)
    }

    private var xDomain: ClosedRange<Double> {
        let first = samples.first?.second ?? 0
        let last = samples.last?.second ?? 0
        return first...max(first + 1, last)
    }

    private var plottedDomain: ClosedRange<Double> {
        let values = samples.map(\.value).filter { $0.isFinite && (invert ? ($0 > 0 && $0 < 3_600) : $0 > 0) }
        let low = values.min() ?? (invert ? 300 : 0)
        let high = values.max() ?? (invert ? 600 : 1)
        if invert {
            let pad = max((high - low) * 0.18, 15)
            let lower = -(high + pad)
            let upper = -(low - pad)
            if upper > lower { return lower...upper }
            return (lower - 1)...(lower + 1)
        }
        let span = high - low
        let pad = span > 0 ? max(span * 0.18, 0.5) : max(abs(high) * 0.08, 1)
        return (low - pad)...(high + pad)
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(SkyTheme.Color.separator.opacity(0.55))
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
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(SkyTheme.Color.separator.opacity(0.45))
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(yText(number))
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                }
            }
        }
    }

    private func yText(_ number: Double) -> String {
        if invert {
            let label = Format.pace(-number)
            return label == "—" ? "" : label
        }
        return String(Int(number.rounded()))
    }
}

private struct ZoneShareRow: View {
    var name: String
    var range: String
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let width = max(0, min(1, fraction.isFinite ? fraction : 0)) * geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SkyTheme.Color.separator.opacity(0.28))
                    .frame(width: geo.size.width, height: geo.size.height)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.35))
                    .frame(width: width, height: geo.size.height)
                HStack(spacing: 8) {
                    Text(name)
                        .font(SkyTheme.Font.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                        .lineLimit(1)
                    Text(range)
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text(percentText)
                        .font(SkyTheme.Font.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(SkyTheme.Color.ink)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(height: 32)
        .accessibilityElement(children: .combine)
    }

    private var percentText: String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

private struct ElevationChartCard: View {
    var points: [SeriesPoint]
    var climb: String
    var peak: String

    private var samples: [ChartSample] {
        WorkoutDetailMath.plotSamples(points)
    }

    private var showsChart: Bool { samples.count >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionTitle(title: "爬升高度")
            if climb != "—" || peak != "—" {
                HStack(alignment: .top, spacing: 8) {
                    MetricHeadline(value: climb, unit: "米", label: "累计爬升", color: SkyTheme.Color.Metric.elevation)
                    MetricHeadline(value: peak, unit: "米", label: "最高海拔", color: SkyTheme.Color.Metric.elevation)
                }
            }
            if showsChart {
                chart
                    .frame(height: 168)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("爬升高度，累计爬升 \(climb) 米，最高海拔 \(peak) 米")
            } else {
                Text("这次没有采集到")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, SkyTheme.Spacing.related)
            }
        }
        .detailCard()
    }

    private var chart: some View {
        let domain = yDomain
        return Chart(samples) { sample in
            AreaMark(
                x: .value("秒", sample.second),
                yStart: .value("底", domain.lower),
                yEnd: .value("值", sample.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        SkyTheme.Color.Metric.elevation.opacity(0.28),
                        SkyTheme.Color.Metric.elevation.opacity(0.04)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("秒", sample.second),
                y: .value("值", sample.value)
            )
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .foregroundStyle(SkyTheme.Color.Metric.elevation)
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: domain.lower...domain.upper)
        .chartXAxis { timeAxis }
        .chartYAxis { valueAxis }
        .chartLegend(.hidden)
    }

    private var xDomain: ClosedRange<Double> {
        let first = samples.first?.second ?? 0
        let last = samples.last?.second ?? 0
        return first...max(first + 1, last)
    }

    /// Domain uses every finite sample, not the downsampled curve, so the true peak stays on scale.
    private var yDomain: (lower: Double, upper: Double) {
        let source = points.map(\.value).filter(\.isFinite)
        let values = source.isEmpty ? samples.map(\.value).filter(\.isFinite) : source
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let span = high - low
        let pad = span > 0 ? max(span * 0.18, 0.5) : max(abs(high) * 0.08, 1)
        return (low - pad, high + pad)
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(SkyTheme.Color.separator.opacity(0.55))
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
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(SkyTheme.Color.separator.opacity(0.45))
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

private struct DetailChartCard: View {
    var title: String
    var points: [SeriesPoint]
    var leading: String?
    var trailing: String?
    var kind: Kind
    var valueDigits: Int = 0

    enum Kind {
        case line
        case pace
        case area
    }

    private var samples: [ChartSample] {
        WorkoutDetailMath.plotSamples(points)
    }

    private var showsChart: Bool { samples.count >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionTitle(title: title)
            if showsChart {
                if leading != nil || trailing != nil {
                    HStack(spacing: 8) {
                        Text(leading ?? "")
                            .frame(maxWidth: .infinity)
                        Text(trailing ?? "")
                            .frame(maxWidth: .infinity)
                    }
                    .font(SkyTheme.Font.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(SkyTheme.Color.ink)
                }
                chart
                    .frame(height: 168)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(chartLabel)
            } else {
                if let leading {
                    Text(leading)
                        .font(SkyTheme.Font.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(SkyTheme.Color.ink)
                }
                Text("这次没有采集到")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, SkyTheme.Spacing.related)
            }
        }
        .detailCard()
    }

    private var chartLabel: String {
        [title, leading, trailing].compactMap { $0 }.joined(separator: "，")
    }

    @ViewBuilder
    private var chart: some View {
        let domain = yDomain
        Chart(samples) { sample in
            if kind == .area {
                AreaMark(
                    x: .value("秒", sample.second),
                    yStart: .value("底", domain.lower),
                    yEnd: .value("值", sample.value)
                )
                .foregroundStyle(SkyTheme.Color.chartTrack.opacity(0.18))
            }
            LineMark(
                x: .value("秒", sample.second),
                y: .value("值", kind == .pace ? -sample.value : sample.value)
            )
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .foregroundStyle(SkyTheme.Color.chartTrack)
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: kind == .pace ? paceDomain : (domain.lower...domain.upper))
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .chartLegend(.hidden)
    }

    private var xDomain: ClosedRange<Double> {
        let first = samples.first?.second ?? 0
        let last = samples.last?.second ?? 0
        return first...max(first + 1, last)
    }

    private var yDomain: (lower: Double, upper: Double) {
        let values = samples.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let span = high - low
        let pad = span > 0 ? max(span * 0.18, 0.5) : max(abs(high) * 0.08, 1)
        return (low - pad, high + pad)
    }

    private var paceDomain: ClosedRange<Double> {
        let values = samples.map(\.value).filter { $0 > 0 && $0 < 3_600 }
        let low = values.min() ?? 300
        let high = values.max() ?? 600
        let pad = max((high - low) * 0.18, 15)
        let lower = -(high + pad)
        let upper = -(low - pad)
        if upper > lower { return lower...upper }
        return (lower - 1)...(lower + 1)
    }

    private var xAxis: some AxisContent {
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

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(SkyTheme.Color.separator.opacity(0.55))
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(yText(number))
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                }
            }
        }
    }

    private func yText(_ number: Double) -> String {
        if kind == .pace {
            let label = Format.pace(-number)
            return label == "—" ? "" : label
        }
        if valueDigits > 0 {
            return String(format: "%.\(valueDigits)f", number)
        }
        return String(Int(number.rounded()))
    }
}

private struct DetailSectionTitle: View {
    var title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: SkyTheme.Spacing.related) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SkyTheme.Color.primary)
                .frame(width: 4, height: 16)
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
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ChartSample: Identifiable {
    var id: Int
    var second: Double
    var value: Double
}

private struct ZoneBand {
    var name: String
    var range: String
    var lower: Double
    var upper: Double

    func contains(_ value: Double) -> Bool {
        value >= lower && value < upper
    }
}

private struct ZoneShare: Identifiable {
    var name: String
    var range: String
    var seconds: Double
    var fraction: Double

    var id: String { name }
}

private enum WorkoutDetailMath {
    /// Same draft cutoffs as `ZoneScale.pace`. Names are the shared zone language.
    static let paceBands: [ZoneBand] = [
        ZoneBand(name: "有氧基础", range: "≥7'00\"", lower: 420, upper: .infinity),
        ZoneBand(name: "有氧耐力", range: "6'00\"–6'59\"", lower: 360, upper: 420),
        ZoneBand(name: "乳酸阈值", range: "5'30\"–5'59\"", lower: 330, upper: 360),
        ZoneBand(name: "速度耐力", range: "5'00\"–5'29\"", lower: 300, upper: 330),
        ZoneBand(name: "冲刺能力", range: "<5'00\"", lower: 0.001, upper: 300)
    ]

    /// Same draft cutoffs as `ZoneScale.heart` (190 bpm reference, not a lab test).
    static let heartBands: [ZoneBand] = [
        ZoneBand(name: "有氧基础", range: "<114", lower: 0.001, upper: 114),
        ZoneBand(name: "有氧耐力", range: "114–132", lower: 114, upper: 133),
        ZoneBand(name: "乳酸阈值", range: "133–151", lower: 133, upper: 152),
        ZoneBand(name: "速度耐力", range: "152–170", lower: 152, upper: 171),
        ZoneBand(name: "冲刺能力", range: "≥171", lower: 171, upper: .infinity)
    ]

    struct ElevationProfile {
        var points: [SeriesPoint]
        var gate: Double
    }

    static func positive(_ points: [SeriesPoint]) -> [SeriesPoint] {
        points.filter { $0.value.isFinite && $0.value > 0 }
    }

    static func runningPace(_ points: [SeriesPoint]) -> [SeriesPoint] {
        points.filter { $0.value.isFinite && $0.value > 0 && $0.value < 3_600 }
    }

    static func mean(_ points: [SeriesPoint]) -> Double? {
        let values = positive(points).map(\.value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Stored average when the workout recorded one. Otherwise the series mean.
    static func displayAverage(stored: Double, points: [SeriesPoint]) -> Double? {
        if stored > 0 { return stored }
        return mean(points)
    }

    static func extreme(_ points: [SeriesPoint], fastest: Bool) -> Double? {
        let values = positive(points).map(\.value)
        guard !values.isEmpty else { return nil }
        return fastest ? values.min() : values.max()
    }

    static func format(_ value: Double?, digits: Int) -> String {
        guard let value, value > 0, value.isFinite else { return "—" }
        if digits <= 0 { return String(Int(value.rounded())) }
        return String(format: "%.\(digits)f", value)
    }

    /// Time in each band.
    ///
    /// A gap longer than `TrainingSeriesMath.pauseGapSeconds` is a pause and is
    /// left out, matching the training average. That rule is right for pace,
    /// which is sampled about every 10–20 seconds of movement.
    ///
    /// Heart rate is not. HealthKit samples are thinned to `HealthSeries.maxPoints`
    /// (720). On a long workout the stored points sit more than 30 seconds apart,
    /// so every interval was classified as a pause and every zone reported 0%
    /// while the chart still drew the series. When the pause rule counts nothing,
    /// treat the series' own spacing as the sample interval: keep gaps up to
    /// 1.5× the median, drop a hole that is much longer, and split each kept
    /// interval across the bands the value crosses.
    static func shares(points: [SeriesPoint], bands: [ZoneBand]) -> [ZoneShare] {
        let ordered = uniqued(points)
        let held = dwell(ordered, bands: bands, limit: TrainingSeriesMath.pauseGapSeconds, interpolate: false)
        if held.reduce(0, +) > 0 || ordered.count < 2 {
            return packaged(bands, held)
        }
        let gaps = (1..<ordered.count).map { ordered[$0].second - ordered[$0 - 1].second }.filter { $0 > 0 }
        guard let typical = median(gaps) else { return packaged(bands, held) }
        let limit = max(TrainingSeriesMath.pauseGapSeconds, typical * 1.5)
        let crossed = dwell(ordered, bands: bands, limit: limit, interpolate: true)
        return packaged(bands, crossed)
    }

    private static func dwell(
        _ ordered: [SeriesPoint],
        bands: [ZoneBand],
        limit: Double,
        interpolate: Bool
    ) -> [Double] {
        var seconds = Array(repeating: 0.0, count: bands.count)
        guard ordered.count >= 2 else { return seconds }
        for index in 1..<ordered.count {
            let dt = ordered[index].second - ordered[index - 1].second
            guard dt > 0, dt <= limit else { continue }
            let start = ordered[index - 1].value
            let end = ordered[index].value
            if interpolate && start != end {
                addCrossed(&seconds, from: start, to: end, dt: dt, bands: bands)
            } else if let band = bands.firstIndex(where: { $0.contains(start) }) {
                seconds[band] += dt
            }
        }
        return seconds
    }

    /// Linear in time. The fraction of the interval between two values is the
    /// fraction of `dt`, which is the same split the heart-rate stroke uses.
    private static func addCrossed(
        _ seconds: inout [Double],
        from start: Double,
        to end: Double,
        dt: Double,
        bands: [ZoneBand]
    ) {
        let span = end - start
        guard span != 0 else { return }
        var knots = [start]
        knots.append(contentsOf: edges(between: start, and: end, bands: bands))
        knots.append(end)
        for index in 1..<knots.count {
            let share = abs(knots[index] - knots[index - 1]) / abs(span) * dt
            let probe = knots[index - 1] + (knots[index] - knots[index - 1]) * 0.5
            guard let band = bands.firstIndex(where: { $0.contains(probe) }) else { continue }
            seconds[band] += share
        }
    }

    private static func packaged(_ bands: [ZoneBand], _ seconds: [Double]) -> [ZoneShare] {
        let total = seconds.reduce(0, +)
        return zip(bands, seconds).map { band, time in
            ZoneShare(
                name: band.name,
                range: band.range,
                seconds: time,
                fraction: total > 0 ? time / total : 0
            )
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Band edges strictly between two readings, in the direction of travel.
    private static func edges(between start: Double, and end: Double, bands: [ZoneBand]) -> [Double] {
        guard start.isFinite, end.isFinite, start != end else { return [] }
        let low = min(start, end)
        let high = max(start, end)
        var found: [Double] = []
        for band in bands {
            for edge in [band.lower, band.upper] where edge.isFinite && edge > low && edge < high {
                if found.allSatisfy({ abs($0 - edge) > 0.000_001 }) {
                    found.append(edge)
                }
            }
        }
        found.sort()
        if start > end { found.reverse() }
        return found
    }

    static func elevationProfile(_ workout: WorkoutRecord) -> ElevationProfile {
        let stored = workout.elevation.filter(\.value.isFinite)
        if isMeaningfulElevation(stored.map(\.value)) {
            return ElevationProfile(points: stored, gate: 0.5)
        }
        return ElevationProfile(points: routeElevation(workout), gate: 1)
    }

    static func displayedClimb(_ workout: WorkoutRecord, profile: ElevationProfile) -> Double {
        if workout.elevationGainMeters > 0 { return workout.elevationGainMeters }
        return climbDrop(profile.points, gate: profile.gate).climb
    }

    static func climbDrop(_ points: [SeriesPoint], gate: Double) -> (climb: Double, drop: Double) {
        let ordered = uniqued(points)
        guard ordered.count >= 2 else { return (0, 0) }
        var climb = 0.0
        var drop = 0.0
        for index in 1..<ordered.count {
            let delta = ordered[index].value - ordered[index - 1].value
            if delta > gate {
                climb += delta
            } else if delta < -gate {
                drop -= delta
            }
        }
        return (climb, drop)
    }

    /// Evenly samples the series and always keeps the minimum and maximum.
    /// Times stay strictly increasing. The point cap is honored unless the only
    /// remaining points are those extrema.
    static func plotSamples(_ points: [SeriesPoint], limit: Int = 90) -> [ChartSample] {
        let unique = uniqued(points)
        guard unique.count >= 2 else { return [] }
        let cap = max(2, limit)
        let finite = points.filter { $0.second.isFinite && $0.value.isFinite }
        let low = finite.min { $0.value < $1.value }
        let high = finite.max { $0.value < $1.value }

        var chosen: [SeriesPoint]
        if unique.count <= cap {
            chosen = unique
        } else {
            let step = max(1, unique.count / cap)
            chosen = []
            chosen.reserveCapacity(cap)
            for index in stride(from: 0, to: unique.count, by: step) {
                chosen.append(unique[index])
            }
            if let last = unique.last, chosen.last?.second != last.second {
                chosen.append(last)
            }
        }
        chosen = includingExtrema(chosen, low: low, high: high, cap: cap)
        return chosen.enumerated().map { offset, point in
            ChartSample(id: offset, second: point.second, value: point.value)
        }
    }

    /// Inserts the true min and max. A sample already at that time keeps the more extreme value
    /// so the chart does not plot two points on one second.
    private static func includingExtrema(
        _ samples: [SeriesPoint],
        low: SeriesPoint?,
        high: SeriesPoint?,
        cap: Int
    ) -> [SeriesPoint] {
        var rows = samples
        if let high {
            rows = merging(rows, extreme: high, replaces: { $0 > $1 })
        }
        if let low, low.second != high?.second {
            rows = merging(rows, extreme: low, replaces: { $0 < $1 })
        }
        rows.sort { $0.second < $1.second }
        var collapsed: [SeriesPoint] = []
        collapsed.reserveCapacity(rows.count)
        for row in rows {
            if let last = collapsed.last, last.second == row.second {
                if row.value == high?.value || (row.value == low?.value && last.value != high?.value) {
                    collapsed[collapsed.count - 1] = SeriesPoint(second: row.second, value: row.value)
                }
            } else {
                collapsed.append(row)
            }
        }
        guard collapsed.count > cap else { return collapsed }
        let protected = Set([low?.second, high?.second].compactMap { $0 })
        var trimmed = collapsed
        while trimmed.count > cap {
            let middle = trimmed.indices.filter { index in
                let second = trimmed[index].second
                if protected.contains(second) { return false }
                return index != 0 && index != trimmed.count - 1
            }
            let pool = middle.isEmpty
                ? trimmed.indices.filter { !protected.contains(trimmed[$0].second) }
                : middle
            guard !pool.isEmpty else { break }
            trimmed.remove(at: pool[pool.count / 2])
        }
        return trimmed
    }

    private static func merging(
        _ rows: [SeriesPoint],
        extreme: SeriesPoint,
        replaces: (Double, Double) -> Bool
    ) -> [SeriesPoint] {
        if let index = rows.firstIndex(where: { $0.second == extreme.second }) {
            guard replaces(extreme.value, rows[index].value) else { return rows }
            var copy = rows
            copy[index] = SeriesPoint(second: extreme.second, value: extreme.value)
            return copy
        }
        return rows + [SeriesPoint(second: extreme.second, value: extreme.value)]
    }

    struct ZoneSegment: Identifiable {
        var id: Int
        var name: String
        var samples: [ChartSample]
    }

    /// Contiguous runs of one zone. The boundary sample is repeated so the stroke stays continuous.
    static func zoneSegments(samples: [ChartSample], bands: [ZoneBand]) -> [ZoneSegment] {
        guard let first = samples.first, !bands.isEmpty else { return [] }
        var segments: [ZoneSegment] = []
        var name = zoneName(first.value, bands: bands)
        var current: [ChartSample] = [first]
        var nextSegment = 0
        var nextID = (samples.map(\.id).max() ?? 0) + 1
        for sample in samples.dropFirst() {
            let sampleName = zoneName(sample.value, bands: bands)
            if sampleName != name {
                segments.append(ZoneSegment(id: nextSegment, name: name, samples: current))
                nextSegment += 1
                let bridge = ChartSample(
                    id: nextID,
                    second: current[current.count - 1].second,
                    value: current[current.count - 1].value
                )
                nextID += 1
                name = sampleName
                current = [bridge, sample]
            } else {
                current.append(sample)
            }
        }
        segments.append(ZoneSegment(id: nextSegment, name: name, samples: current))
        return segments
    }

    /// Same zone colors as `zoneSegments`, but the stroke changes color where the
    /// line crosses a cutoff. Used for heart rate, whose plotted samples are far
    /// enough apart that one segment can pass through several bands.
    static func boundaryZoneSegments(samples: [ChartSample], bands: [ZoneBand]) -> [ZoneSegment] {
        guard samples.count >= 2, !bands.isEmpty else {
            return zoneSegments(samples: samples, bands: bands)
        }
        var nextID = (samples.map(\.id).max() ?? 0) + 1
        func mint(_ second: Double, _ value: Double) -> ChartSample {
            defer { nextID += 1 }
            return ChartSample(id: nextID, second: second, value: value)
        }
        var segments: [ZoneSegment] = []
        for index in 1..<samples.count {
            let start = samples[index - 1]
            let end = samples[index]
            var knots: [(second: Double, value: Double)] = [(start.second, start.value)]
            let deltaValue = end.value - start.value
            let deltaTime = end.second - start.second
            if deltaValue != 0 {
                for edge in edges(between: start.value, and: end.value, bands: bands) {
                    let t = (edge - start.value) / deltaValue
                    knots.append((start.second + deltaTime * t, edge))
                }
            }
            knots.append((end.second, end.value))
            for knot in 1..<knots.count {
                let left = knots[knot - 1]
                let right = knots[knot]
                let probe = left.value + (right.value - left.value) * 0.5
                let name = zoneName(probe, bands: bands)
                let endSample = mint(right.second, right.value)
                if let last = segments.indices.last, segments[last].name == name {
                    segments[last].samples.append(endSample)
                } else {
                    segments.append(ZoneSegment(
                        id: segments.count,
                        name: name,
                        samples: [mint(left.second, left.value), endSample]
                    ))
                }
            }
        }
        return segments
    }

    private static func zoneName(_ value: Double, bands: [ZoneBand]) -> String {
        if let band = bands.first(where: { $0.contains(value) }) {
            return band.name
        }
        return bands[0].name
    }

    private static func routeElevation(_ workout: WorkoutRecord) -> [SeriesPoint] {
        let route = workout.route
        guard route.count >= 2 else { return [] }
        guard isMeaningfulElevation(route.map(\.altitude)) else { return [] }
        if let origin = route.compactMap(\.timestamp).min() {
            let stamped = route.compactMap { point -> SeriesPoint? in
                guard let time = point.timestamp else { return nil }
                return SeriesPoint(second: max(0, time.timeIntervalSince(origin)), value: point.altitude)
            }
            if isMeaningfulElevation(stamped.map(\.value)) {
                return stamped
            }
        }
        let span = max(workout.duration, 1)
        let lastIndex = Double(route.count - 1)
        return route.enumerated().map { index, point in
            SeriesPoint(second: span * Double(index) / lastIndex, value: point.altitude)
        }
    }

    private static func isMeaningfulElevation(_ values: [Double]) -> Bool {
        let finite = values.filter(\.isFinite)
        guard finite.count >= 2, let high = finite.max(), let low = finite.min() else { return false }
        if high - low > 0.4 { return true }
        return high > 1 || low < -1
    }

    private static func uniqued(_ points: [SeriesPoint]) -> [SeriesPoint] {
        var result: [SeriesPoint] = []
        var last = -Double.greatestFiniteMagnitude
        for point in points.sorted(by: { $0.second < $1.second }) {
            guard point.second.isFinite, point.value.isFinite, point.second > last else { continue }
            result.append(point)
            last = point.second
        }
        return result
    }
}

private extension View {
    func detailCard() -> some View {
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

/// SwiftUI turns the interactive pop off once the system back button is hidden.
/// This puts that edge-swipe back without taking over pans that start away from the edge.
private struct InteractivePopGestureEnabler: UIViewRepresentable {
    func makeUIView(context: Context) -> PopEnablerView {
        let view = PopEnablerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PopEnablerView, context: Context) {
        view.install()
    }
}

private final class PopEnablerView: UIView, UIGestureRecognizerDelegate {
    private weak var pop: UIGestureRecognizer?
    private weak var previousDelegate: UIGestureRecognizerDelegate?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            pop?.delegate = previousDelegate
            pop = nil
            previousDelegate = nil
            return
        }
        install()
        DispatchQueue.main.async { [weak self] in
            self?.install()
        }
    }

    func install() {
        guard window != nil, let navigation = enclosingNavigationController(),
              let gesture = navigation.interactivePopGestureRecognizer else { return }
        if pop !== gesture {
            previousDelegate = gesture.delegate
            pop = gesture
        }
        gesture.isEnabled = true
        gesture.delegate = self
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation = enclosingNavigationController(), navigation.viewControllers.count > 1 else {
            return false
        }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let location = pan.location(in: pan.view)
        guard location.x <= 40 else { return false }
        let velocity = pan.velocity(in: pan.view)
        if abs(velocity.x) < 1, abs(velocity.y) < 1 { return true }
        return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: gestureRecognizer.view)
        return point.x <= 40
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
