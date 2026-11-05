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
        }
        .background(SkyTheme.Color.grouped)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background {
            InteractivePopGestureEnabler()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private func detail(_ workout: WorkoutRecord, viewportHeight: CGFloat, topInset: CGFloat) -> some View {
        let mapHeight = viewportHeight * 0.56 + topInset
        return VStack(spacing: 0) {
            mapHeader(workout, height: mapHeight, topInset: topInset)
                .padding(.top, -topInset)
            summarySheet(workout)
            VStack(spacing: SkyTheme.Spacing.section) {
                DetailSplitsCard(workout: workout)
                paceCard(workout)
                heartCard(workout)
                seriesCard(
                    title: "步频（步/分）",
                    points: WorkoutDetailMath.positive(workout.cadenceSeries),
                    average: WorkoutDetailMath.displayAverage(
                        stored: workout.resolvedAverageCadence,
                        points: workout.cadenceSeries
                    ),
                    extremeTitle: "最大",
                    digits: 0
                )
                seriesCard(
                    title: "步幅（米/步）",
                    points: WorkoutDetailMath.positive(workout.stride),
                    average: WorkoutDetailMath.displayAverage(
                        stored: workout.averageStrideMeters,
                        points: workout.stride
                    ),
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
    }

    private func mapHeader(_ workout: WorkoutRecord, height: CGFloat, topInset: CGFloat) -> some View {
        ZStack(alignment: .top) {
            RouteMap(
                route: workout.route,
                cornerRadius: 0,
                routeColor: SkyTheme.Color.primary,
                routeLineWidth: 5,
                showsEndpoints: workout.route.count >= 2,
                hidesMapControls: true,
                fitToken: fitToken
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
                Spacer()
                if workout.route.count >= 2 {
                    mapButton(system: "location.viewfinder", label: "回到轨迹") {
                        fitToken += 1
                    }
                }
            }
            .padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.top, topInset + SkyTheme.Spacing.related)
        }
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

    private func summarySheet(_ workout: WorkoutRecord) -> some View {
        VStack(alignment: .leading, spacing: SkyTheme.Spacing.screenInset) {
            Capsule()
                .fill(SkyTheme.Color.tertiary)
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            HStack(alignment: .center, spacing: 12) {
                avatar(for: workout)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline(workout))
                        .font(SkyTheme.Font.title3)
                        .foregroundStyle(SkyTheme.Color.ink)
                        .lineLimit(1)
                    Text(subheadline(workout))
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

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: SkyTheme.Spacing.screenInset
            ) {
                MetricCell(value: distanceText(workout), label: "距离（公里）", prominent: true, hero: true)
                MetricCell(value: Format.pace(workout.averagePaceSecPerKm), label: "配速", prominent: true, hero: true)
                MetricCell(value: Format.clock(workout.duration), label: "时长", prominent: false, hero: true)
                MetricCell(value: countText(Double(workout.sessionLoad)), label: "负荷", prominent: false, hero: false)
                MetricCell(value: Format.integer(workout.averageHeartRate), label: "心率", prominent: false, hero: false)
                MetricCell(value: climbText(workout), label: "爬升（米）", prominent: false, hero: false)
                MetricCell(value: strideText(workout.averageStrideMeters), label: "步幅（米）", prominent: false, hero: false)
                MetricCell(value: Format.integer(workout.resolvedAverageCadence), label: "步频", prominent: false, hero: false)
                MetricCell(value: countText(workout.energyKilocalories), label: "能量（千卡）", prominent: false, hero: false)
            }
            .padding(SkyTheme.Spacing.cardPadding)
            .background(SkyTheme.Color.grouped, in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous))

            Text("上滑查看分段与图表")
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
        .padding(.top, 12)
        .padding(.bottom, SkyTheme.Spacing.section)
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
        .padding(.top, -SkyTheme.Radius.sheet)
    }

    @ViewBuilder
    private func avatar(for workout: WorkoutRecord) -> some View {
        if app.isLoggedIn {
            AccountAvatarFace(
                name: app.account?.name ?? "",
                image: app.accountAvatar,
                diameter: SkyTheme.Spacing.touchMin,
                ring: SkyTheme.Color.cardBorder
            )
        } else {
            Image(systemName: workout.sport == .running ? "figure.run" : "figure.hiking")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SkyTheme.Color.onPrimary)
                .frame(width: SkyTheme.Spacing.touchMin, height: SkyTheme.Spacing.touchMin)
                .background(SkyTheme.Color.primary, in: Circle())
                .accessibilityHidden(true)
        }
    }

    private func headline(_ workout: WorkoutRecord) -> String {
        if app.isLoggedIn {
            let name = app.account?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { return name }
        }
        return workout.sport.title
    }

    private func subheadline(_ workout: WorkoutRecord) -> String {
        let when = "\(Format.dayTime(workout.start))–\(Format.time(workout.end))"
        if headline(workout) == workout.sport.title {
            return when
        }
        return "\(workout.sport.title) · \(when)"
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
        return DetailChartCard(
            title: "配速（分钟/公里）",
            points: points,
            leading: stat("平均", Format.pace(workout.averagePaceSecPerKm)),
            trailing: stat("最佳", Format.pace(WorkoutDetailMath.extreme(points, fastest: true) ?? 0)),
            kind: .pace,
            zones: points.count >= 2 ? WorkoutDetailMath.shares(points: points, bands: WorkoutDetailMath.paceBands) : [],
            zoneTitle: "配速区间",
            footnote: points.count >= 2 ? "草稿区间，不是医疗标准。" : nil
        )
    }

    private func heartCard(_ workout: WorkoutRecord) -> some View {
        let points = WorkoutDetailMath.positive(workout.heartRate)
        let average = WorkoutDetailMath.displayAverage(stored: workout.averageHeartRate, points: points)
        return DetailChartCard(
            title: "心率（次/分）",
            points: points,
            leading: stat("平均", Format.integer(average ?? 0)),
            trailing: stat("最大", Format.integer(WorkoutDetailMath.extreme(points, fastest: false) ?? 0)),
            kind: .line,
            zones: points.count >= 2 ? WorkoutDetailMath.shares(points: points, bands: WorkoutDetailMath.heartBands) : [],
            zoneTitle: "心率区间",
            footnote: points.count >= 2 ? "草稿区间，不是医疗标准。" : nil
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
        let change = WorkoutDetailMath.climbDrop(profile.points, gate: profile.gate)
        let climb = WorkoutDetailMath.displayedClimb(workout, profile: profile)
        let hasLine = profile.points.count >= 2
        return DetailChartCard(
            title: "海拔变化（米）",
            points: profile.points,
            leading: hasLine || climb > 0 ? "总爬升 \(Int(climb.rounded())) 米" : nil,
            trailing: hasLine ? "总下降 \(Int(change.drop.rounded())) 米" : nil,
            kind: .area
        )
    }

    private func stat(_ title: String, _ value: String) -> String? {
        guard value != "—" else { return nil }
        return "\(title) \(value)"
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

private struct MetricCell: View {
    var value: String
    var label: String
    var prominent: Bool
    var hero: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(hero ? SkyTheme.Font.title : SkyTheme.Font.title3)
                .fontWeight(.bold)
                .foregroundStyle(prominent ? SkyTheme.Color.primary : SkyTheme.Color.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct DetailSplitsCard: View {
    var workout: WorkoutRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionTitle(title: "分段信息", trailing: workout.splits.isEmpty ? nil : "每公里")
            if workout.splits.isEmpty {
                Text("这次没有每公里数据")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, SkyTheme.Spacing.related)
            } else {
                splitRow(["圈数", "时间", "距离", "配速", "心率", "步频"], header: true)
                ForEach(workout.splits) { split in
                    splitRow([
                        "\(split.index)",
                        split.partial ? "—" : Format.clock(split.paceSecPerKm),
                        split.partial ? "未满" : "1.00",
                        Format.pace(split.paceSecPerKm),
                        Format.integer(split.heartRate),
                        Format.integer(split.cadence)
                    ])
                }
                Rectangle()
                    .fill(SkyTheme.Color.separator)
                    .frame(height: 1)
                    .padding(.vertical, 4)
                    splitRow([
                    "总计",
                    Format.clock(workout.duration),
                    Format.kilometers(workout.distanceMeters),
                    Format.pace(workout.averagePaceSecPerKm),
                    Format.integer(workout.averageHeartRate),
                    Format.integer(workout.resolvedAverageCadence)
                ])
            }
        }
        .detailCard()
    }

    private func splitRow(_ cells: [String], header: Bool = false) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                Text(cell)
                    .font(header ? SkyTheme.Font.caption : SkyTheme.Font.footnote)
                    .fontWeight(header ? .regular : .semibold)
                    .foregroundStyle(color(header: header, column: column))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func color(header: Bool, column: Int) -> Color {
        if header { return SkyTheme.Color.secondary }
        if column == 3 { return SkyTheme.Color.primary }
        return SkyTheme.Color.ink
    }
}

private struct DetailChartCard: View {
    var title: String
    var points: [SeriesPoint]
    var leading: String?
    var trailing: String?
    var kind: Kind
    var zones: [ZoneShare] = []
    var zoneTitle: String?
    var footnote: String?
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
                if let zoneTitle, !zones.isEmpty {
                    zoneBlock(zoneTitle)
                }
                if let footnote {
                    Text(footnote)
                        .font(SkyTheme.Font.caption)
                        .foregroundStyle(SkyTheme.Color.secondary)
                }
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

    private func zoneBlock(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.ink)
            ForEach(zones) { share in
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
                            Capsule()
                                .fill(SkyTheme.Color.separator.opacity(0.45))
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
    static let paceBands: [ZoneBand] = [
        ZoneBand(name: "区间 1", range: "≥7'00\"", lower: 420, upper: .infinity),
        ZoneBand(name: "区间 2", range: "6'00\"–6'59\"", lower: 360, upper: 420),
        ZoneBand(name: "区间 3", range: "5'30\"–5'59\"", lower: 330, upper: 360),
        ZoneBand(name: "区间 4", range: "5'00\"–5'29\"", lower: 300, upper: 330),
        ZoneBand(name: "区间 5", range: "<5'00\"", lower: 0.001, upper: 300)
    ]

    static let heartBands: [ZoneBand] = [
        ZoneBand(name: "区间 1", range: "<114", lower: 0.001, upper: 114),
        ZoneBand(name: "区间 2", range: "114–132", lower: 114, upper: 133),
        ZoneBand(name: "区间 3", range: "133–151", lower: 133, upper: 152),
        ZoneBand(name: "区间 4", range: "152–170", lower: 152, upper: 171),
        ZoneBand(name: "区间 5", range: "≥171", lower: 171, upper: .infinity)
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

    static func shares(points: [SeriesPoint], bands: [ZoneBand]) -> [ZoneShare] {
        let ordered = uniqued(points)
        var seconds = Array(repeating: 0.0, count: bands.count)
        if ordered.count >= 2 {
            for index in 1..<ordered.count {
                let dt = ordered[index].second - ordered[index - 1].second
                guard dt > 0, dt <= 30 else { continue }
                let value = ordered[index - 1].value
                guard let band = bands.firstIndex(where: { $0.contains(value) }) else { continue }
                seconds[band] += dt
            }
        }
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

    static func plotSamples(_ points: [SeriesPoint], limit: Int = 90) -> [ChartSample] {
        let unique = uniqued(points)
        guard unique.count >= 2 else { return [] }
        let step = max(1, unique.count / max(limit, 2))
        var picked: [SeriesPoint] = []
        for index in stride(from: 0, to: unique.count, by: step) {
            picked.append(unique[index])
        }
        if let last = unique.last, picked.last?.second != last.second {
            picked.append(last)
        }
        return picked.enumerated().map { offset, point in
            ChartSample(id: offset, second: point.second, value: point.value)
        }
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
