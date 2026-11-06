import MapKit
import SwiftUI

private enum RecordFeedSection: Hashable {
    case list
    case stats
}

/// Records tab. Short white cards: map thumbnail, sport, duration, and a three-column metric row.
struct RecordFeedView: View {
    @EnvironmentObject private var app: PhoneAppState
    @State private var section: RecordFeedSection = .list
    @State private var topWorkoutID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            RecordSectionControl(selection: $section)
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.top, SkyTheme.Spacing.related)
                .padding(.bottom, SkyTheme.Spacing.related)
                .frame(maxWidth: .infinity)
                .background(SkyTheme.Color.grouped)
                .zIndex(1)
            switch section {
            case .list:
                recordList
            case .stats:
                RecordStatsPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyTheme.Color.grouped)
        .task {
            await app.importFromApple()
        }
    }

    private var monthLabel: String {
        let workout = app.workouts.first { $0.id == topWorkoutID } ?? app.workouts.first
        return workout.map { Format.monthTitle($0.start) } ?? ""
    }

    @ViewBuilder
    private var recordList: some View {
        if app.workouts.isEmpty {
            empty
        } else {
            VStack(spacing: 0) {
                Text(monthLabel)
                    .font(SkyTheme.Font.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(SkyTheme.Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SkyTheme.Spacing.screenInset)
                    .padding(.bottom, SkyTheme.Spacing.related)
                    .background(SkyTheme.Color.grouped)
                    .zIndex(1)
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SkyTheme.Spacing.related) {
                        if !app.banner.isEmpty {
                            Text(app.banner)
                                .font(SkyTheme.Font.footnote)
                                .foregroundStyle(SkyTheme.Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(app.workouts) { workout in
                            NavigationLink(value: RecordRoute.detail(workout.id)) {
                                RecordSummaryCard(workout: workout)
                            }
                            .buttonStyle(.plain)
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: RecordTopAnchorsKey.self,
                                        value: [RecordTopAnchor(
                                            id: workout.id,
                                            minY: geo.frame(in: .scrollView).minY
                                        )]
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, SkyTheme.Spacing.screenInset)
                    .padding(.top, SkyTheme.Spacing.related)
                    .padding(.bottom, SkyTheme.Spacing.related)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(RecordTopAnchorsKey.self) { anchors in
                    guard let next = Self.topmostWorkoutID(in: anchors), next != topWorkoutID else { return }
                    topWorkoutID = next
                }
                .refreshable {
                    await app.importFromApple()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                if topWorkoutID == nil {
                    topWorkoutID = app.workouts.first?.id
                }
            }
            .onChange(of: app.workouts.map(\.id)) { _, ids in
                guard let topWorkoutID else {
                    self.topWorkoutID = ids.first
                    return
                }
                if !ids.contains(topWorkoutID) {
                    self.topWorkoutID = ids.first
                }
            }
        }
    }

    /// The card whose top has reached the list, or the first card when none have.
    private static func topmostWorkoutID(in anchors: [RecordTopAnchor]) -> UUID? {
        let line: CGFloat = 12
        let crossed = anchors.filter { $0.minY <= line }
        if let current = crossed.max(by: { $0.minY < $1.minY }) {
            return current.id
        }
        return anchors.min(by: { $0.minY < $1.minY })?.id
    }

    private var empty: some View {
        VStack(spacing: SkyTheme.Spacing.related) {
            Text("还没有训练记录")
                .font(SkyTheme.Font.headline)
                .foregroundStyle(SkyTheme.Color.ink)
            Text("完成一次徒步或跑步后，会出现在这里。")
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
                .multilineTextAlignment(.center)
            if !app.banner.isEmpty {
                Text(app.banner)
                    .font(SkyTheme.Font.footnote)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordSectionControl: View {
    @Binding var selection: RecordFeedSection

    var body: some View {
        HStack(spacing: 4) {
            segment(.list, title: "记录列表")
            segment(.stats, title: "统计数据")
        }
        .padding(4)
        .background(SkyTheme.Color.card, in: RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: selection)
    }

    private func segment(_ section: RecordFeedSection, title: String) -> some View {
        let selected = selection == section
        return Button {
            selection = section
        } label: {
            Text(title)
                .font(SkyTheme.Font.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(selected ? SkyTheme.Color.onPrimary : SkyTheme.Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 36)
                .background {
                    if selected {
                        Capsule().fill(SkyTheme.Color.primary)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RecordStatsPage: View {
    @EnvironmentObject private var app: PhoneAppState
    @State private var window: StatsWindow = .week

    private var stats: TrainingStats {
        app.stats(for: window)
    }

    var body: some View {
        VStack(spacing: 0) {
            periodSwitcher
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.bottom, SkyTheme.Spacing.screenInset)
                .frame(maxWidth: .infinity)
                .background(SkyTheme.Color.grouped)
                .zIndex(1)
            ScrollView {
                statsGrid
                    .padding(.horizontal, SkyTheme.Spacing.screenInset)
                    .padding(.bottom, SkyTheme.Spacing.section)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var periodSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(StatsWindow.allCases) { item in
                let selected = window == item
                Button {
                    window = item
                } label: {
                    Text(item.rawValue)
                        .font(SkyTheme.Font.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(selected ? SkyTheme.Color.onPrimary : SkyTheme.Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 36)
                        .background {
                            if selected {
                                Capsule().fill(SkyTheme.Color.primary)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(SkyTheme.Color.card, in: Capsule(style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: window)
    }

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            alignment: .leading,
            spacing: SkyTheme.Spacing.screenInset
        ) {
            cell("总距离", distanceText)
            cell("平均配速", RecordCardText.pace(stats.averagePaceSecPerKm))
            cell("平均心率", Format.integer(stats.averageHeartRate))
            cell("总爬升", metersText(stats.elevationGainMeters))
            cell("平均步频", Format.integer(stats.averageCadence))
            cell("平均步幅", strideText)
            cell("总负荷", loadText)
            cell("训练评分", scoreText)
        }
        .padding(SkyTheme.Spacing.cardPadding)
        .background(SkyTheme.Color.card, in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous))
        .shadow(
            color: SkyTheme.Shadow.card.color.opacity(SkyTheme.Shadow.card.opacity),
            radius: SkyTheme.Shadow.card.radius,
            y: SkyTheme.Shadow.card.y
        )
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(SkyTheme.Font.title3)
                .fontWeight(.bold)
                .foregroundStyle(SkyTheme.Color.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var distanceText: String {
        guard stats.distanceMeters > 1 else { return "—" }
        return String(format: "%.1f km", stats.distanceMeters / 1000)
    }

    private func metersText(_ meters: Double) -> String {
        guard meters > 0 else { return "—" }
        return "\(Int(meters.rounded())) m"
    }

    private var strideText: String {
        guard stats.averageStrideMeters > 0 else { return "—" }
        return "\(Int((stats.averageStrideMeters * 100).rounded())) cm"
    }

    private var loadText: String {
        guard stats.totalSessionLoad > 0 else { return "—" }
        return String(Int(stats.totalSessionLoad.rounded()))
    }

    private var scoreText: String {
        guard stats.trainingScore > 0 else { return "—" }
        return String(Int(stats.trainingScore.rounded()))
    }
}

private struct RecordTopAnchor: Equatable {
    var id: UUID
    var minY: CGFloat
}

private struct RecordTopAnchorsKey: PreferenceKey {
    static var defaultValue: [RecordTopAnchor] = []

    static func reduce(value: inout [RecordTopAnchor], nextValue: () -> [RecordTopAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

/// Confirmed record-card metrics. 10pt inset is the design measurement; the spacing scale has no 10.
private enum RecordCardLayout {
    static let thumbnail: CGFloat = 84
    static let inset: CGFloat = 10
    static let contentGap: CGFloat = 10
    /// Tightest spacing step, so the sport line stays inside the 84pt thumbnail.
    static let stackSpacing: CGFloat = 4
}

struct RecordSummaryCard: View {
    var workout: WorkoutRecord
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: RecordCardLayout.contentGap) {
            RecordMapThumbnail(points: workout.route, sport: workout.sport)
            VStack(alignment: .leading, spacing: RecordCardLayout.stackSpacing) {
                sportLine
                header
                metrics
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The 84pt thumbnail anchors the card at the default type size. Larger Dynamic Type grows the card.
        .frame(height: dynamicTypeSize <= .large ? RecordCardLayout.thumbnail : nil)
        .padding(RecordCardLayout.inset)
        .background(SkyTheme.Color.card, in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous))
        .shadow(
            color: SkyTheme.Shadow.card.color.opacity(SkyTheme.Shadow.card.opacity),
            radius: SkyTheme.Shadow.card.radius,
            y: SkyTheme.Shadow.card.y
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }

    private var sportLine: some View {
        Text(workout.sport.title)
            .font(SkyTheme.Font.caption)
            .fontWeight(.semibold)
            .foregroundStyle(SkyTheme.Color.ink)
            .lineLimit(1)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: SkyTheme.Spacing.related) {
            Text(RecordCardText.clock(workout.trainingDuration))
                .font(SkyTheme.Font.headline)
                .fontWeight(.bold)
                .foregroundStyle(SkyTheme.Color.ink)
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(RecordCardText.started(workout.start))
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
        }
    }

    /// Three columns, no rules: a 2×2 on the left, then load, then score.
    /// The 2×2 splits into two equal tracks, so the row is four equal columns.
    private var metrics: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                distanceColumn
                paceColumn
                columnLabel("训练负荷")
                columnLabel("训练评分")
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                smallMetric(heartText)
                smallMetric(cadenceText)
                columnValue(loadText, SkyTheme.Color.ink)
                columnValue(scoreText, SkyTheme.Color.primary)
            }
        }
    }

    private var distanceColumn: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(distanceValue)
                .font(SkyTheme.Font.headline)
                .fontWeight(.bold)
                .foregroundStyle(SkyTheme.Color.ink)
                .monospacedDigit()
            if let distanceUnit {
                Text(distanceUnit)
                    .font(SkyTheme.Font.caption)
                    .foregroundStyle(SkyTheme.Color.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paceColumn: some View {
        Text(RecordCardText.pace(workout.averagePaceSecPerKm))
            .font(SkyTheme.Font.caption)
            .foregroundStyle(SkyTheme.Color.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smallMetric(_ text: String) -> some View {
        Text(text)
            .font(SkyTheme.Font.caption)
            .foregroundStyle(SkyTheme.Color.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func columnLabel(_ title: String) -> some View {
        Text(title)
            .font(SkyTheme.Font.caption)
            .foregroundStyle(SkyTheme.Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func columnValue(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(SkyTheme.Font.headline)
            .fontWeight(.bold)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var distanceValue: String {
        RecordCardText.distance(workout.distanceMeters).value
    }

    private var distanceUnit: String? {
        RecordCardText.distance(workout.distanceMeters).unit
    }

    private var heartText: String {
        let value = Format.integer(workout.averageHeartRate)
        return value == "—" ? value : "\(value) bpm"
    }

    private var cadenceText: String {
        let value = Format.integer(workout.resolvedAverageCadence)
        return value == "—" ? value : "\(value) spm"
    }

    private var loadText: String {
        let load = workout.sessionLoad
        return load > 0 ? "\(load)" : "—"
    }

    /// No training-score field on `WorkoutRecord`. Keep the column, and use the same empty mark as other metrics.
    private var scoreText: String { "—" }

    private var accessibilitySummary: String {
        let distance = distanceUnit.map { "\(distanceValue) \($0)" } ?? distanceValue
        return [
            workout.sport.title,
            "训练时间 \(RecordCardText.clock(workout.trainingDuration))",
            "开始 \(RecordCardText.started(workout.start))",
            "距离 \(distance)",
            "配速 \(RecordCardText.pace(workout.averagePaceSecPerKm))",
            "平均心率 \(heartText)",
            "平均步频 \(cadenceText)",
            "训练负荷 \(loadText)",
            "训练评分 \(scoreText)"
        ].joined(separator: "，")
    }
}

private enum RecordCardText {
    private static let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    static func started(_ date: Date) -> String {
        let index = max(0, min(6, calendar.component(.weekday, from: date) - 1))
        return "\(startFormatter.string(from: date))（周\(weekdays[index])）"
    }

    /// Prime marks, no `/km`. Gray caption in the card.
    static func pace(_ secondsPerKm: Double) -> String {
        guard secondsPerKm.isFinite, secondsPerKm > 0, secondsPerKm < 3_600 else { return "—" }
        let total = Int(secondsPerKm.rounded())
        return "\(total / 60)′\(String(format: "%02d", total % 60))″"
    }

    static func distance(_ meters: Double) -> (value: String, unit: String?) {
        guard meters > 1 else { return ("—", nil) }
        return (String(format: "%.1f", meters / 1000), "km")
    }
}

struct RecordMapThumbnail: View {
    var points: [GeoPoint]
    var sport: SportKind

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var renderedKey = ""

    private var cacheKey: String {
        RecordMapSnapshot.key(for: points, scale: displayScale)
    }

    private var shownImage: UIImage? {
        if renderedKey == cacheKey {
            return image
        }
        return RecordMapSnapshot.cachedImage(forKey: cacheKey)
    }

    var body: some View {
        ZStack {
            SkyTheme.Color.cardBorder
            if let shownImage {
                Image(uiImage: shownImage)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else if points.count >= 2 {
                RecordTrackLine(points: points)
            } else {
                Image(systemName: sport == .running ? "figure.run" : "figure.hiking")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(SkyTheme.Color.primary)
            }
        }
        .frame(width: RecordCardLayout.thumbnail, height: RecordCardLayout.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous))
        .accessibilityHidden(true)
        .task(id: cacheKey) {
            guard points.count >= 2 else {
                image = nil
                renderedKey = cacheKey
                return
            }
            let rendered = await RecordMapSnapshot.image(for: points, scale: displayScale)
            guard !Task.isCancelled else { return }
            image = rendered
            renderedKey = cacheKey
        }
    }
}

/// Resumes a snapshot continuation once. Cancel can race the completion handler.
private final class SnapshotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(
        _ continuation: CheckedContinuation<MKMapSnapshotter.Snapshot?, Never>,
        with snapshot: MKMapSnapshotter.Snapshot?
    ) {
        lock.lock()
        let already = resumed
        resumed = true
        lock.unlock()
        if !already {
            continuation.resume(returning: snapshot)
        }
    }
}

/// Static MapKit snapshot with a primary route. The flat track is only the stand-in before tiles arrive.
private enum RecordMapSnapshot {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        return cache
    }()

    static func key(for points: [GeoPoint], scale: CGFloat) -> String {
        var hash: UInt64 = UInt64(points.count)
        let step = max(points.count / 16, 1)
        var index = 0
        while index < points.count {
            let point = points[index]
            hash = hash &* 31 &+ UInt64(bitPattern: Int64((point.latitude * 10_000).rounded()))
            hash = hash &* 31 &+ UInt64(bitPattern: Int64((point.longitude * 10_000).rounded()))
            index += step
        }
        return "\(hash)-\(Int((scale * 10).rounded()))"
    }

    static func cachedImage(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    static func image(for points: [GeoPoint], scale: CGFloat) async -> UIImage? {
        let key = self.key(for: points, scale: scale) as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard points.count >= 2, let region = region(for: points) else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: RecordCardLayout.thumbnail, height: RecordCardLayout.thumbnail)
        options.scale = max(scale, 1)
        options.mapType = .standard
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(displayScale: options.scale)
        ])

        let snapshotter = MKMapSnapshotter(options: options)
        let box = SnapshotResume()
        let snapshot: MKMapSnapshotter.Snapshot? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                snapshotter.start { snapshot, _ in
                    box.resume(continuation, with: snapshot)
                }
            }
        } onCancel: {
            snapshotter.cancel()
        }
        guard let snapshot, !Task.isCancelled else { return nil }
        let rendered = render(points: points, on: snapshot)
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    private static func region(for points: [GeoPoint]) -> MKCoordinateRegion? {
        guard let first = points.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for point in points {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        // Extra span leaves room for the end pin inside the rounded thumbnail.
        let pad = 1.85
        let minimum = 0.0012
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(maxLat - minLat, minimum) * pad,
                longitudeDelta: max(maxLon - minLon, minimum) * pad
            )
        )
    }

    private static func render(points: [GeoPoint], on snapshot: MKMapSnapshotter.Snapshot) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size, format: format)
        let coordinates = simplified(points).map(\.coordinate)
        let stroke = UIColor(SkyTheme.Color.primary)
        let hole = UIColor(SkyTheme.Color.card)
        return renderer.image { _ in
            snapshot.image.draw(at: .zero)
            guard coordinates.count >= 2 else { return }
            let path = UIBezierPath()
            path.lineWidth = 3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (index, coordinate) in coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            stroke.setStroke()
            path.stroke()
            if let last = coordinates.last {
                drawPin(at: snapshot.point(for: last), fill: stroke, hole: hole)
            }
        }
    }

    private static func drawPin(at tip: CGPoint, fill: UIColor, hole: UIColor) {
        let radius: CGFloat = 3.6
        let center = CGPoint(x: tip.x, y: tip.y - radius - 2)
        let head = UIBezierPath(
            ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        )
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: tip.x - radius * 0.72, y: center.y + radius * 0.35))
        tail.addLine(to: tip)
        tail.addLine(to: CGPoint(x: tip.x + radius * 0.72, y: center.y + radius * 0.35))
        tail.close()
        fill.setFill()
        tail.fill()
        head.fill()
        let pupil = radius * 0.38
        hole.setFill()
        UIBezierPath(
            ovalIn: CGRect(x: center.x - pupil, y: center.y - pupil, width: pupil * 2, height: pupil * 2)
        ).fill()
    }

    private static func simplified(_ points: [GeoPoint], limit: Int = 180) -> [GeoPoint] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            let position = min(points.count - 1, Int((Double(index) * step).rounded()))
            return points[position]
        }
    }
}

/// Primary route on the card fill while the map snapshot is still loading, or if tiles fail.
private struct RecordTrackLine: View {
    var points: [GeoPoint]

    var body: some View {
        Canvas { context, size in
            let spots = projected(in: size)
            guard spots.count >= 2 else { return }
            var path = Path()
            path.move(to: spots[0])
            for point in spots.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path,
                with: .color(SkyTheme.Color.primary),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
            if let last = spots.last {
                let head = CGRect(x: last.x - 3.6, y: last.y - 12, width: 7.2, height: 7.2)
                context.fill(Path(ellipseIn: head), with: .color(SkyTheme.Color.primary))
                var tail = Path()
                tail.move(to: CGPoint(x: last.x - 2.6, y: last.y - 6))
                tail.addLine(to: last)
                tail.addLine(to: CGPoint(x: last.x + 2.6, y: last.y - 6))
                tail.closeSubpath()
                context.fill(tail, with: .color(SkyTheme.Color.primary))
                let pupil = CGRect(x: last.x - 1.4, y: last.y - 9.8, width: 2.8, height: 2.8)
                context.fill(Path(ellipseIn: pupil), with: .color(SkyTheme.Color.card))
            }
        }
    }

    private func projected(in size: CGSize) -> [CGPoint] {
        guard let first = points.first, points.count >= 2 else { return [] }
        let midLatitude = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let cosLat = max(cos(midLatitude * .pi / 180), 0.2)
        let east = points.map { CGFloat(($0.longitude - first.longitude) * 111_320 * cosLat) }
        let north = points.map { CGFloat(($0.latitude - first.latitude) * 111_320) }
        let minX = east.min() ?? 0
        let maxX = east.max() ?? 0
        let minY = north.min() ?? 0
        let maxY = north.max() ?? 0
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        let pad: CGFloat = 12
        let width = max(size.width - pad * 2, 1)
        let height = max(size.height - pad * 2, 1)
        let scale = min(width / spanX, height / spanY)
        let usedWidth = spanX * scale
        let usedHeight = spanY * scale
        let originX = pad + (width - usedWidth) / 2
        let originY = pad + (height - usedHeight) / 2
        return zip(east, north).map { easting, northing in
            CGPoint(
                x: originX + (easting - minX) * scale,
                y: originY + (maxY - northing) * scale
            )
        }
    }
}

