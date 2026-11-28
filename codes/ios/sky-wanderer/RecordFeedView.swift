import SwiftUI
import UIKit

/// Records tab. Month title stays fixed at the top. Sport filter is a left
/// compass tool (same roulette as training), with 全部 prepended. Docked, the
/// tool’s top edge sits on the screen horizontal midline.
struct RecordFeedView: View {
    var isActive: Bool = true
    @Binding var peripheralChromeVisible: Bool

    @EnvironmentObject private var app: PhoneAppState
    @State private var revealedWorkoutID: UUID?
    @State private var pendingDeleteID: UUID?
    /// Month of the card closest to the top of the list. Empty until the first layout sample.
    @State private var monthTitle = ""
    /// Nil is 全部. Applied to the rows on screen; `app.workouts` is left as stored.
    @State private var sportFilter: SportKind?
    @State private var showsMetricHelp = false
    @State private var showSportRoulette = false
    @State private var filterToolFlight: CGFloat = 0
    @State private var rouletteTransitionTask: Task<Void, Never>?
    @ObservedObject private var basemapCenter = SkyBasemapCenter.shared

    init(
        isActive: Bool = true,
        peripheralChromeVisible: Binding<Bool> = .constant(true)
    ) {
        self.isActive = isActive
        self._peripheralChromeVisible = peripheralChromeVisible
    }

    var body: some View {
        GeometryReader { geo in
            feed
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if !app.workouts.isEmpty {
                        filterToolChrome(in: geo)
                    }
                }
                .overlay {
                    if showSportRoulette {
                        SportRouletteOverlay(
                            filter: $sportFilter,
                            sports: RecordListFilter.sports(in: app.workouts),
                            screenWidth: geo.size.width,
                            screenHeight: geo.size.height,
                            onDismiss: { closeSportRoulette(animated: true) }
                        )
                        .transition(.opacity)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyTheme.Color.grouped.ignoresSafeArea())
        .task {
            await app.importFromApple()
        }
        .task(id: PlateBackfillKey(ids: app.workouts.map(\.id), tianditu: basemapCenter.mode == .tianditu)) {
            // List cells only read disk/memory plates. Missing ones fill in
            // slowly here so cold launch never opens an MKMapView per card.
            let mapped = app.workouts.filter {
                RecordListThumbnailKind.resolve(routeCount: $0.listThumbnailPointCount) != .swatch
            }
            await RecordMapThumbnails.shared.backfill(
                workouts: mapped,
                size: CGSize(
                    width: RecordListCardLayout.mapWidth,
                    height: RecordListCardLayout.mapHeight
                )
            )
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
        .sheet(isPresented: $showsMetricHelp) {
            RecordMetricHelpSheet()
                .preferredColorScheme(.light)
        }
        .onChange(of: app.workouts.map(\.sport)) { _, sports in
            // Stays mounted when the list is replaced by the empty state, so a
            // cleared log cannot keep a sport that is no longer loaded.
            if let sportFilter, !sports.contains(sportFilter) {
                self.sportFilter = nil
            }
        }
        .onChange(of: app.workouts.isEmpty) { _, empty in
            if empty {
                closeSportRoulette(animated: false)
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                closeSportRoulette(animated: false)
            }
            publishPeripheralChrome()
        }
        .onChange(of: showSportRoulette) { _, _ in
            publishPeripheralChrome()
        }
        .onDisappear {
            rouletteTransitionTask?.cancel()
            rouletteTransitionTask = nil
            showSportRoulette = false
            filterToolFlight = 0
            publishPeripheralChrome()
        }
    }

    private var filterSymbol: String {
        sportFilter?.symbol ?? SportRouletteItem.all.symbol
    }

    private var filterAccessibilityLabel: String {
        sportFilter?.title ?? SportRouletteItem.all.title
    }

    private func filterToolChrome(in geo: GeometryProxy) -> some View {
        // Docked: top edge on the screen horizontal midline. Flight still ends
        // at screen center so the roulette arc midline matches.
        let point = StartMapChrome.filterToolPosition(
            progress: ChromeLength(filterToolFlight),
            screenWidth: ChromeLength(geo.size.width),
            screenHeight: ChromeLength(geo.size.height)
        )
        return Button {
            if showSportRoulette || filterToolFlight > 0.01 {
                closeSportRoulette(animated: true)
            } else {
                openSportRoulette()
            }
        } label: {
            Image(systemName: filterSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SkyTheme.Color.onStarryGray)
                .frame(
                    width: CGFloat(StartMapChrome.toolDiameter),
                    height: CGFloat(StartMapChrome.toolDiameter)
                )
                .background(SkyTheme.Color.starryGray, in: Circle())
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(filterAccessibilityLabel)
        .accessibilityHint("筛选运动类型")
        .scaleEffect(1 + CGFloat(SportRouletteGeometry.centerScale - 1) * filterToolFlight)
        .opacity(showSportRoulette ? 0 : 1)
        .position(x: CGFloat(point.x), y: CGFloat(point.y))
        .zIndex(2)
    }

    private func publishPeripheralChrome() {
        let next = !isActive || (!showSportRoulette && filterToolFlight < 0.01)
        if peripheralChromeVisible != next {
            peripheralChromeVisible = next
        }
    }

    private func openSportRoulette() {
        rouletteTransitionTask?.cancel()
        rouletteTransitionTask = Task { @MainActor in
            withAnimation(.easeOut(duration: Double(StartMapChrome.rouletteOpenCompanionFade))) {
                peripheralChromeVisible = false
            }
            withAnimation(.spring(
                response: Double(StartMapChrome.rouletteOpenFly),
                dampingFraction: 0.86
            )) {
                filterToolFlight = 1
            }
            let flyNs = UInt64(Double(StartMapChrome.rouletteOpenFly) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: flyNs)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showSportRoulette = true
            }
        }
    }

    private func closeSportRoulette(animated: Bool) {
        rouletteTransitionTask?.cancel()
        if !animated {
            showSportRoulette = false
            filterToolFlight = 0
            publishPeripheralChrome()
            return
        }
        rouletteTransitionTask = Task { @MainActor in
            withAnimation(.easeOut(duration: Double(StartMapChrome.rouletteCloseFade))) {
                showSportRoulette = false
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(
                response: Double(StartMapChrome.rouletteCloseFly),
                dampingFraction: 0.86
            )) {
                filterToolFlight = 0
            }
            let flyNs = UInt64(Double(StartMapChrome.rouletteCloseFly) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: flyNs)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Double(StartMapChrome.rouletteOpenCompanionFade))) {
                peripheralChromeVisible = isActive
            }
        }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )
    }

    /// Rows on screen. Filtering does not rewrite the stored log.
    private var visibleWorkouts: [WorkoutRecord] {
        RecordListFilter.apply(sportFilter, to: app.workouts)
    }

    /// Newest month first. The span starts on the newest visible workout of that month.
    private var monthSpans: [RecordMonthSpan] {
        Format.recordMonthSpans(dates: visibleWorkouts.map(\.start))
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

    /// Sticky month title on the grouped light band. Sport filter lives on the left compass tool.
    private var monthTitleBar: some View {
        HStack(alignment: .center, spacing: CGFloat(RecordListCardLayout.headerGap)) {
            RecordMonthTitle(title: displayedMonthTitle)
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, SkyTheme.Spacing.screenInset)
        .padding(.trailing, SkyTheme.Spacing.screenInset)
        .padding(.bottom, CGFloat(RecordListCardLayout.filterBarBottom))
        .background(SkyTheme.Color.grouped, ignoresSafeAreaEdges: .top)
        .zIndex(1)
    }

    private var recordScroll: some View {
        let workouts = visibleWorkouts
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
        let entries = RecordFeedList.rows(spans: spans).map { row in
            RecordFeedEntry(id: feedEntryID(row, workouts: workouts), row: row)
        }
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
                if workouts.isEmpty, let sportFilter {
                    Text("没有\(sportFilter.title)记录")
                        .font(SkyTheme.Font.footnote)
                        .foregroundStyle(SkyTheme.Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SkyTheme.Spacing.screenInset)
                }
                ForEach(entries) { entry in
                    switch entry.row {
                    case .monthHeader(let title):
                        RecordMonthSectionLabel(title: title)
                    case .card(let index):
                        let workout = workouts[index]
                        RecordSwipeCard(
                            workout: workout,
                            revealedID: $revealedWorkoutID,
                            onRequestDelete: { pendingDeleteID = workout.id },
                            onExplainMetrics: { showsMetricHelp = true }
                        )
                        .padding(.bottom, SkyTheme.Spacing.related)
                        .background {
                            RecordMonthProbe(title: monthByIndex[index])
                        }
                    }
                }
            }
            .padding(.top, CGFloat(RecordListCardLayout.firstCardGap))
            .padding(.bottom, SkyTheme.Spacing.related)
        }
        // On the scroll view itself. The month title is the sibling above it, and the
        // top edge effect is applied after this, so neither sits between the list and the refresh task.
        .refreshable {
            await app.importFromApple()
        }
        .coordinateSpace(.named(RecordListSpace.viewport))
        .scrollEdgeEffectStyle(.hard, for: .top)
        // iOS 26 SDK: scrollEdgeEffectHidden(_:for:). Hides the top blur so a card cannot fade out above the list.
        .scrollEdgeEffectHidden(true, for: .top)
        .contentMargins(.top, 0, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyTheme.Color.grouped)
        .onChange(of: app.workouts.map(\.id)) { _, ids in
            if let revealedWorkoutID, !ids.contains(revealedWorkoutID) {
                self.revealedWorkoutID = nil
            }
        }
        .onChange(of: sportFilter) { _, _ in
            revealedWorkoutID = nil
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
            Text("完成一次训练，或从 Apple 健康导入后，会出现在这里。")
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

private struct PlateBackfillKey: Hashable {
    var ids: [UUID]
    var tianditu: Bool
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
    @ScaledMetric(relativeTo: .title3) private var monthSize: CGFloat = 20
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
            .font(.system(size: monthSize, weight: .bold))
            .foregroundStyle(SkyTheme.Color.starryGray)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .opacity(text.isEmpty ? 0 : opacity)
            .accessibilityHidden(true)
    }
}

private enum RecordListSpace {
    static let viewport = "recordListViewport"
}

private struct RecordFeedEntry: Identifiable {
    var id: String
    var row: RecordFeedList.Row
}

private func feedEntryID(_ row: RecordFeedList.Row, workouts: [WorkoutRecord]) -> String {
    switch row {
    case .monthHeader(let title):
        return "month-\(title)"
    case .card(let index):
        return workouts[index].id.uuidString
    }
}

/// In-list year-month. One point larger than headline and bold. Sits on the same
/// grouped light band as the sticky top date; leading edge matches the card map.
/// No month probe: the sticky title follows cards only.
private struct RecordMonthSectionLabel: View {
    var title: String
    @ScaledMetric(relativeTo: .headline) private var monthSize: CGFloat = 18

    var body: some View {
        Text(title)
            .font(.system(size: monthSize, weight: .bold))
            .foregroundStyle(SkyTheme.Color.starryGray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(RecordListCardLayout.monthSectionLeading))
            .padding(.trailing, CGFloat(RecordListCardLayout.monthSectionTrailing))
            .padding(.top, CGFloat(RecordListCardLayout.monthSectionTop))
            .padding(.bottom, CGFloat(RecordListCardLayout.monthSectionBottom))
            .background(SkyTheme.Color.grouped)
            .accessibilityAddTraits(.isHeader)
    }
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
                    value: [RecordMonthAnchor(
                        title: title,
                        minY: Double(frame.minY),
                        maxY: Double(frame.maxY)
                    )]
                )
        }
        .allowsHitTesting(false)
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
    var onExplainMetrics: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var suppressNavigation = false
    @State private var deleteArmed = false
    @State private var gestureToken = 0
    @State private var rowHeight: CGFloat = 0
    @State private var dragBase: CGFloat = 0
    @State private var explainFrames: [CGRect] = []

    private var explainSpace: String { "record-explain-\(workout.id.uuidString)" }

    private var snap: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86)
    }

    var body: some View {
        NavigationLink(value: RecordRoute.detail(workout.id)) {
            RecordSummaryCard(
                workout: workout,
                explainSpace: explainSpace,
                onExplainMetrics: onExplainMetrics
            )
        }
        .buttonStyle(.plain)
        .overlay {
            // Above the link, only over load and score, so those taps do not open the record.
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                ForEach(Array(explainFrames.enumerated()), id: \.offset) { _, rect in
                    Color.clear
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .contentShape(Rectangle())
                        .position(x: rect.midX, y: rect.midY)
                        .onTapGesture { onExplainMetrics() }
                        .accessibilityHidden(true)
                }
            }
        }
        .coordinateSpace(.named(explainSpace))
        .onPreferenceChange(RecordExplainFramesKey.self) { frames in
            if frames != explainFrames {
                explainFrames = frames
            }
        }
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
            .background(SkyTheme.Color.danger)
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
