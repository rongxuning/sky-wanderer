import SwiftUI
import UIKit

/// Records tab. Month headers pin at the top. Cards show a pale track, not a map.
struct RecordFeedView: View {
    @EnvironmentObject private var app: PhoneAppState
    @State private var revealedWorkoutID: UUID?
    @State private var pendingDeleteID: UUID?

    var body: some View {
        recordList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SkyTheme.Color.grouped)
            .task {
                await app.importFromApple()
            }
            .alert(
                "删除这条训练记录？",
                isPresented: deleteAlertPresented,
                presenting: pendingDeleteID
            ) { id in
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if revealedWorkoutID == id {
                        revealedWorkoutID = nil
                    }
                    app.deleteWorkout(id: id)
                }
            } message: { _ in
                EmptyView()
            }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )
    }

    /// Newest month first. The span starts on the newest workout of that month.
    private var monthSpans: [RecordMonthSpan] {
        Format.recordMonthSpans(dates: app.workouts.map(\.start))
    }

    @ViewBuilder
    private var recordList: some View {
        if app.workouts.isEmpty {
            empty
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !app.banner.isEmpty {
                        Text(app.banner)
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(SkyTheme.Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SkyTheme.Spacing.screenInset)
                            .padding(.top, SkyTheme.Spacing.related)
                            .padding(.bottom, SkyTheme.Spacing.related)
                    }
                    ForEach(monthSpans) { span in
                        Section {
                            ForEach(Array(app.workouts[span.range])) { workout in
                                RecordSwipeCard(
                                    workout: workout,
                                    revealedID: $revealedWorkoutID,
                                    onRequestDelete: { pendingDeleteID = workout.id }
                                )
                                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                                .padding(.bottom, SkyTheme.Spacing.related)
                            }
                        } header: {
                            monthHeader(span.title)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .refreshable {
                await app.importFromApple()
            }
            .onChange(of: app.workouts.map(\.id)) { _, ids in
                if let revealedWorkoutID, !ids.contains(revealedWorkoutID) {
                    self.revealedWorkoutID = nil
                }
            }
        }
    }

    /// Pinned section header. The next month's header pushes this one off the top.
    private func monthHeader(_ title: String) -> some View {
        Text(title)
            .font(SkyTheme.Font.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(SkyTheme.Color.ink)
            .padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.top, SkyTheme.Spacing.related)
            .padding(.bottom, SkyTheme.Spacing.related * 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SkyTheme.Color.grouped)
            .zIndex(1)
            .accessibilityAddTraits(.isHeader)
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

/// Analysis tab. Same summary the records segment used to show, with no page title.
struct AnalysisPage: View {
    @EnvironmentObject private var app: PhoneAppState

    var body: some View {
        RecordStatsPage()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SkyTheme.Color.grouped)
            .task {
                await app.importFromApple()
            }
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
                .padding(.top, SkyTheme.Spacing.related)
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

private struct RecordSwipeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// The trailing delete control. Wider than the 44pt minimum touch target.
private enum RecordSwipeMetrics {
    static let buttonWidth: CGFloat = 72
    static let gap: CGFloat = SkyTheme.Spacing.related
    static var revealed: CGFloat { buttonWidth + gap }
}

/// Slides the record card left to reveal 删除. Releasing the swipe only opens or closes that
/// button. Tapping it asks first; the card's link does not open while the finger is dragging.
/// The pan does not begin for a vertical or diagonal move, so that touch stays with the list.
private struct RecordSwipeCard: View {
    var workout: WorkoutRecord
    @Binding var revealedID: UUID?
    var onRequestDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var suppressNavigation = false
    @State private var deleteArmed = false
    @State private var gestureToken = 0
    @State private var rowHeight: CGFloat = 0
    @State private var dragBase: CGFloat = 0

    private var snap: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86)
    }

    var body: some View {
        NavigationLink(value: RecordRoute.detail(workout.id)) {
            RecordSummaryCard(workout: workout)
        }
        .buttonStyle(.plain)
        // Hit testing, not disabled: disabled would fade the card while the finger is down.
        .allowsHitTesting(!suppressNavigation && offset == 0)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: RecordSwipeHeightKey.self, value: geo.size.height)
            }
        }
        .offset(x: offset)
        .background(alignment: .trailing) {
            deleteButton
        }
        .overlay {
            if offset != 0 {
                // The trailing gap stays free so a tap lands on 删除 instead of closing the card.
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                    Color.clear
                        .frame(width: RecordSwipeMetrics.revealed)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if deleteArmed {
                Color.clear
                    .frame(width: RecordSwipeMetrics.buttonWidth, height: rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onRequestDelete() }
                    .accessibilityLabel("删除")
            }
        }
        .contentShape(Rectangle())
        // Representable pans attach with gesture(_:). simultaneousGesture requires a SwiftUI Gesture.
        // The delegate still shares the touch with list scroll; shouldBegin stays fail-closed.
        .gesture(deletePan)
        .accessibilityAction(named: Text("删除")) {
            onRequestDelete()
        }
        .onPreferenceChange(RecordSwipeHeightKey.self) { height in
            if height > 0, height != rowHeight {
                rowHeight = height
            }
        }
        .onChange(of: revealedID) { _, id in
            guard id != workout.id, offset != 0 else { return }
            close()
        }
    }

    private var deleteButton: some View {
        Text("删除")
            .font(SkyTheme.Font.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(SkyTheme.Color.onPrimary)
            .frame(width: RecordSwipeMetrics.buttonWidth)
            .frame(height: rowHeight > 0 ? rowHeight : nil)
            .background(
                SkyTheme.Color.danger,
                in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous)
            )
            .opacity(offset < -4 ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var deletePan: RecordDeletePan {
        RecordDeletePan(
            onBegan: {
                dragBase = offset
                gestureToken += 1
                deleteArmed = false
                // Only a horizontal pan reaches here. A vertical scroll never sets this.
                suppressNavigation = true
                revealedID = workout.id
            },
            onChanged: { translation in
                let next = dragBase + translation
                offset = min(0, max(-RecordSwipeMetrics.revealed, next))
            },
            onEnded: { translation, velocity in
                let predicted = RecordCardSwipe.predictedTranslation(
                    translation: Double(translation),
                    velocity: Double(velocity)
                )
                let resting = RecordCardSwipe.restingOffset(
                    base: Double(dragBase),
                    translation: Double(translation),
                    predicted: predicted,
                    revealed: Double(RecordSwipeMetrics.revealed)
                )
                // restingOffset only opens or closes the button. It does not delete.
                let open = resting < 0
                withAnimation(snap) {
                    offset = CGFloat(resting)
                }
                if open {
                    revealedID = workout.id
                } else if revealedID == workout.id {
                    revealedID = nil
                }
                let token = gestureToken
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard token == gestureToken else { return }
                    deleteArmed = open && offset != 0
                    if offset == 0 {
                        suppressNavigation = false
                    }
                }
            }
        )
    }

    private func close() {
        withAnimation(snap) { offset = 0 }
        deleteArmed = false
        suppressNavigation = false
        if revealedID == workout.id {
            revealedID = nil
        }
    }
}

/// Horizontal pan for 删除. `shouldBegin` returns false for a vertical or diagonal move,
/// so the recognizer never claims that touch and the list scroll keeps it.
private struct RecordDeletePan: UIGestureRecognizerRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {}

    func gestureRecognizerShouldBegin(_ recognizer: UIPanGestureRecognizer) -> Bool {
        Self.begins(recognizer)
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        let velocity = recognizer.velocity(in: recognizer.view).x
        switch recognizer.state {
        case .began:
            context.coordinator.claimed = true
            onBegan()
            onChanged(translation)
        case .changed:
            guard context.coordinator.claimed else { return }
            onChanged(translation)
        case .ended:
            guard context.coordinator.claimed else { return }
            context.coordinator.claimed = false
            onEnded(translation, velocity)
        case .cancelled:
            guard context.coordinator.claimed else { return }
            context.coordinator.claimed = false
            onEnded(translation, 0)
        default:
            break
        }
    }

    private static func begins(_ recognizer: UIPanGestureRecognizer) -> Bool {
        let translation = recognizer.translation(in: recognizer.view)
        let velocity = recognizer.velocity(in: recognizer.view)
        return RecordCardSwipe.shouldBeginDeletePan(
            translationX: translation.x,
            translationY: translation.y,
            velocityX: velocity.x,
            velocityY: velocity.y
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var claimed = false

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return RecordDeletePan.begins(pan)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Declining in `shouldBegin` is what keeps a vertical scroll exclusive.
            // Returning true here lets that scroll proceed while this pan is still undecided.
            true
        }
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
        .background(SkyTheme.Color.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                .foregroundStyle(SkyTheme.Color.Metric.duration)
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
                smallMetric(heartText, SkyTheme.Color.Metric.heartRate)
                smallMetric(cadenceText, SkyTheme.Color.Metric.pace)
                columnValue(loadText, SkyTheme.Color.Metric.load)
                columnValue(scoreText, SkyTheme.Color.Metric.score)
            }
        }
    }

    private var distanceColumn: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(distanceValue)
            if let distanceUnit, distanceValue != "—" {
                Text(distanceUnit)
            }
        }
        .font(SkyTheme.Font.headline)
        .fontWeight(.bold)
        .foregroundStyle(figureColor(distanceValue, SkyTheme.Color.Metric.distance))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paceColumn: some View {
        let text = RecordCardText.pace(workout.averagePaceSecPerKm)
        return Text(text)
            .font(SkyTheme.Font.headline)
            .fontWeight(.bold)
            .foregroundStyle(figureColor(text, SkyTheme.Color.Metric.pace))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smallMetric(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(SkyTheme.Font.caption)
            .fontWeight(.bold)
            .foregroundStyle(figureColor(text, color))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
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

    private func figureColor(_ text: String, _ color: Color) -> Color {
        text == "—" ? SkyTheme.Color.secondary : color
    }

    private func columnValue(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(SkyTheme.Font.headline)
            .fontWeight(.bold)
            .foregroundStyle(figureColor(text, color))
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
        let value = Format.integer(workout.resolvedAverageHeartRate)
        return value == "—" ? value : "\(value)次/分"
    }

    private var cadenceText: String {
        let value = Format.integer(workout.resolvedAverageCadence)
        return value == "—" ? value : "\(value)步/分"
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

    /// `14'13"`, no `/公里`. The detail screen keeps the full unit.
    static func pace(_ secondsPerKm: Double) -> String {
        Format.pace(secondsPerKm)
    }

    static func distance(_ meters: Double) -> (value: String, unit: String?) {
        guard meters > 1 else { return ("—", nil) }
        return (String(format: "%.1f", meters / 1000), "公里")
    }
}

/// 84×84 track. No map tiles: the route itself is the thumbnail.
struct RecordMapThumbnail: View {
    var points: [GeoPoint]
    var sport: SportKind

    var body: some View {
        ZStack {
            SkyTheme.Color.cardBorder
            if points.count >= 2 {
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
    }
}

/// Washed brand blue for the list thumbnail. Full `#1E88FE` stays the icon and metric accent.
private enum RecordTrackInk {
    /// 60% of `#1E88FE`. Pale on the light thumbnail, still darker than the `#E4F1FF` fill.
    static let color = SkyTheme.Color.primary.opacity(0.6)
}

/// Pale route on the thumbnail fill. Long traces are sampled down before they are projected.
private struct RecordTrackLine: View {
    var points: [GeoPoint]

    var body: some View {
        let samples = RecordTrackPath.simplified(points)
        Canvas { context, size in
            let spots = Self.projected(samples, in: size)
            guard spots.count >= 2 else { return }
            var path = Path()
            path.move(to: spots[0])
            for point in spots.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path,
                with: .color(RecordTrackInk.color),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
            if let last = spots.last {
                let head = CGRect(x: last.x - 3.6, y: last.y - 12, width: 7.2, height: 7.2)
                context.fill(Path(ellipseIn: head), with: .color(RecordTrackInk.color))
                var tail = Path()
                tail.move(to: CGPoint(x: last.x - 2.6, y: last.y - 6))
                tail.addLine(to: last)
                tail.addLine(to: CGPoint(x: last.x + 2.6, y: last.y - 6))
                tail.closeSubpath()
                context.fill(tail, with: .color(RecordTrackInk.color))
                let pupil = CGRect(x: last.x - 1.4, y: last.y - 9.8, width: 2.8, height: 2.8)
                context.fill(Path(ellipseIn: pupil), with: .color(SkyTheme.Color.card))
            }
        }
    }

    private static func projected(_ points: [GeoPoint], in size: CGSize) -> [CGPoint] {
        guard let first = points.first, points.count >= 2 else { return [] }
        var latitudeSum = 0.0
        for point in points {
            latitudeSum += point.latitude
        }
        let midLatitude = latitudeSum / Double(points.count)
        let cosLat = max(cos(midLatitude * .pi / 180), 0.2)
        var east: [CGFloat] = []
        var north: [CGFloat] = []
        east.reserveCapacity(points.count)
        north.reserveCapacity(points.count)
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for point in points {
            let easting = CGFloat((point.longitude - first.longitude) * 111_320 * cosLat)
            let northing = CGFloat((point.latitude - first.latitude) * 111_320)
            east.append(easting)
            north.append(northing)
            minX = min(minX, easting)
            maxX = max(maxX, easting)
            minY = min(minY, northing)
            maxY = max(maxY, northing)
        }
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

