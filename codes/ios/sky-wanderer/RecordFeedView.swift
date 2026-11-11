import SwiftUI
import UIKit

/// Records tab. One month title stays fixed from the top of the screen through the date.
/// Cards scroll only below that bar. Each card draws its track behind the numbers, not in a side slot.
struct RecordFeedView: View {
    @EnvironmentObject private var app: PhoneAppState
    @State private var revealedWorkoutID: UUID?
    @State private var pendingDeleteID: UUID?
    /// Month of the card closest to the top of the list. Empty until the first layout sample.
    @State private var monthTitle = ""

    var body: some View {
        feed
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SkyTheme.Color.grouped.ignoresSafeArea())
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

    /// The bar shows this month. Before the list reports a top card, it uses the newest month.
    private var displayedMonthTitle: String {
        if monthSpans.contains(where: { $0.title == monthTitle }) {
            return monthTitle
        }
        return monthSpans.first?.title ?? ""
    }

    @ViewBuilder
    private var feed: some View {
        if app.workouts.isEmpty {
            empty
        } else {
            // Title outside the scroll view: a rubber-band or a fast flick stays below the date.
            VStack(spacing: 0) {
                monthTitleBar
                recordScroll
            }
        }
    }

    /// Opaque slab from the top of the screen through the month title. The list starts under it.
    private var monthTitleBar: some View {
        RecordMonthTitle(title: displayedMonthTitle)
            .background(SkyTheme.Color.grouped, ignoresSafeAreaEdges: .top)
            .zIndex(1)
    }

    private var recordScroll: some View {
        let workouts = app.workouts
        let spans = monthSpans
        let monthByIndex: [String] = {
            var titles = Array(repeating: "", count: workouts.count)
            for span in spans {
                for index in span.range where titles.indices.contains(index) {
                    titles[index] = span.title
                }
            }
            return titles
        }()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !app.banner.isEmpty {
                    Text(app.banner)
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SkyTheme.Spacing.screenInset)
                        .padding(.top, SkyTheme.Spacing.related)
                        .padding(.bottom, SkyTheme.Spacing.related)
                }
                ForEach(Array(workouts.enumerated()), id: \.element.id) { index, workout in
                    RecordSwipeCard(
                        workout: workout,
                        revealedID: $revealedWorkoutID,
                        onRequestDelete: { pendingDeleteID = workout.id }
                    )
                    .padding(.horizontal, SkyTheme.Spacing.screenInset)
                    .padding(.bottom, SkyTheme.Spacing.related)
                    .background {
                        RecordMonthProbe(title: monthByIndex[index])
                    }
                }
            }
        }
        .coordinateSpace(.named(RecordListSpace.viewport))
        .scrollEdgeEffectStyle(.hard, for: .top)
        // iOS 26 SDK: scrollEdgeEffectHidden(_:for:). Hides the top blur so a card cannot fade out above the list.
        .scrollEdgeEffectHidden(true, for: .top)
        .contentMargins(.top, 0, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyTheme.Color.grouped)
        .refreshable {
            await app.importFromApple()
        }
        .onChange(of: app.workouts.map(\.id)) { _, ids in
            if let revealedWorkoutID, !ids.contains(revealedWorkoutID) {
                self.revealedWorkoutID = nil
            }
        }
        .onPreferenceChange(RecordMonthAnchorKey.self) { anchors in
            guard let title = RecordMonthTracking.topTitle(among: anchors) else { return }
            if title != monthTitle {
                monthTitle = title
            }
        }
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

/// Analysis tab. No page title. Opening the tab still imports from Apple Health once.
struct AnalysisPage: View {
    @EnvironmentObject private var app: PhoneAppState

    var body: some View {
        AnalysisBoard()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SkyTheme.Color.grouped)
            .task {
                await app.importFromApple()
            }
    }
}

/// Fixed month label. The outgoing title fades out while the incoming title fades in, in the same place.
/// Reduce Motion swaps the text with no animation. The opaque bar behind this view stays put.
private struct RecordMonthTitle: View {
    var title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var front = ""
    @State private var back = ""
    /// Which copy is at full opacity. The other copy is the one fading away.
    @State private var frontOnTop = true

    private var frontText: String { front.isEmpty ? title : front }

    var body: some View {
        ZStack(alignment: .topLeading) {
            line(back, opacity: frontOnTop ? 0 : 1)
            line(frontText, opacity: frontOnTop ? 1 : 0)
        }
        .onAppear {
            if front.isEmpty {
                front = title
            }
        }
        .onChange(of: title) { _, newTitle in
            // The first sample matches the title already on screen. Seed it without a fade.
            guard !front.isEmpty else {
                front = newTitle
                return
            }
            let shown = frontOnTop ? frontText : back
            guard !newTitle.isEmpty, newTitle != shown else { return }
            if reduceMotion || shown.isEmpty {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    front = newTitle
                    back = ""
                    frontOnTop = true
                }
                return
            }
            // Park the new title on the hidden copy, then fade the two copies past each other.
            if frontOnTop {
                back = newTitle
            } else {
                front = newTitle
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                frontOnTop.toggle()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }

    private func line(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(SkyTheme.Font.title3)
            .fontWeight(.bold)
            .foregroundStyle(SkyTheme.Color.ink)
            .padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.top, SkyTheme.Spacing.related)
            .padding(.bottom, SkyTheme.Spacing.screenInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(text.isEmpty ? 0 : opacity)
            .accessibilityHidden(true)
    }
}

private enum RecordListSpace {
    static let viewport = "recordListViewport"
}

private struct RecordMonthAnchor: Equatable {
    var title: String
    var minY: CGFloat
    var maxY: CGFloat
}

private struct RecordMonthAnchorKey: PreferenceKey {
    static var defaultValue: [RecordMonthAnchor] = []

    static func reduce(value: inout [RecordMonthAnchor], nextValue: () -> [RecordMonthAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

/// Reports one card's frame in the list viewport. The scroll view names that space.
private struct RecordMonthProbe: View {
    var title: String

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(RecordListSpace.viewport))
            Color.clear
                .preference(
                    key: RecordMonthAnchorKey.self,
                    value: [RecordMonthAnchor(title: title, minY: frame.minY, maxY: frame.maxY)]
                )
        }
        .allowsHitTesting(false)
    }
}

private enum RecordMonthTracking {
    /// Month of the card closest to the top of the visible list.
    /// A card that still crosses the top edge keeps the title until its bottom leaves that edge.
    static func topTitle(among anchors: [RecordMonthAnchor], listTop: CGFloat = 0) -> String? {
        let visible = anchors.filter { anchor in
            !anchor.title.isEmpty
                && anchor.minY.isFinite
                && anchor.maxY.isFinite
                && anchor.maxY > anchor.minY
                && anchor.maxY > listTop
        }
        return visible.min { $0.minY < $1.minY }?.title
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
struct RecordDeletePan: UIGestureRecognizerRepresentable {
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

/// Confirmed record-card metrics. Vertical 10pt inset is the design measurement; the spacing scale has no 10.
private enum RecordCardLayout {
    static let track: CGFloat = 84
    /// ~20, between the 16 card token and the 24 sheet token.
    static let corner: CGFloat = 20
    static let horizontalInset: CGFloat = SkyTheme.Spacing.cardPadding
    static let verticalInset: CGFloat = 10
    /// One step for all four rows.
    static let rowSpacing: CGFloat = 4
}

struct RecordSummaryCard: View {
    var workout: WorkoutRecord

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RecordCardLayout.corner, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if workout.route.count >= 2 {
                RecordTrackLine(points: workout.route)
                    .frame(width: RecordCardLayout.track, height: RecordCardLayout.track)
                    .padding(.trailing, RecordCardLayout.horizontalInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: RecordCardLayout.rowSpacing) {
                titleRow
                timeRow
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
            .padding(.horizontal, RecordCardLayout.horizontalInset)
            .padding(.vertical, RecordCardLayout.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SkyTheme.Color.recordCard, in: cardShape)
        .clipShape(cardShape)
        .shadow(
            color: SkyTheme.Shadow.card.color.opacity(SkyTheme.Shadow.card.opacity),
            radius: SkyTheme.Shadow.card.radius,
            y: SkyTheme.Shadow.card.y
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }

    /// Sport title on the left. The stored line is right-aligned on the same row.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: SkyTheme.Spacing.related) {
            Text(workout.sport.title)
                .font(SkyTheme.Font.caption)
                .fontWeight(.semibold)
                .foregroundStyle(SkyTheme.Color.ink)
                .lineLimit(1)
                .layoutPriority(1)
            Text(quote)
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var timeRow: some View {
        HStack(alignment: .center, spacing: SkyTheme.Spacing.related) {
            Text(RecordCardText.clock(workout.trainingDuration))
                .font(SkyTheme.Font.headline)
                .fontWeight(.bold)
                .foregroundStyle(SkyTheme.Color.Metric.duration)
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            Text(RecordCardText.started(workout.start))
                .font(SkyTheme.Font.caption)
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var quote: String {
        if let stored = RecordMotivation.storedLine(workout.motivationLine) {
            return stored
        }
        return RecordMotivation.line(for: workout.id, healthKitUUID: workout.healthKitUUID)
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
            quote,
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

/// Brand blue kept light enough that the numbers drawn on top stay readable.
private enum RecordTrackInk {
    /// About 38% of `#1E88FE`, inside the 0.35–0.40 band for the background track.
    static let color = SkyTheme.Color.primary.opacity(0.38)
}

/// Route stroke drawn behind the card numbers. Long traces are sampled down before they are projected.
struct RecordTrackLine: View {
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
                let dot = CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: dot), with: .color(RecordTrackInk.color))
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

