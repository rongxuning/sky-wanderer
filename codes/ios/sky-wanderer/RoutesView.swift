import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension GPXFile {
    static var types: [UTType] {
        var list: [UTType] = [.xml, .data]
        if let gpx = UTType(filenameExtension: "gpx") {
            list.insert(gpx, at: 0)
        }
        return list
    }
}

struct RoutesLibraryView: View {
    @EnvironmentObject private var app: PhoneAppState
    @EnvironmentObject private var draft: WorkoutDraft
    @State private var importing = false
    @State private var importError: String?
    @State private var revealedRouteID: String?
    /// Home tab keeps this list and drops the navigation title.
    var embeddedInHome: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                RouteImportButton { importing = true }
            }
            .padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.top, SkyTheme.Spacing.related)
            .padding(.bottom, SkyTheme.Spacing.related)
            if app.importedRoutes.isEmpty {
                emptyState
            } else {
                routeList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SkyTheme.Color.grouped.ignoresSafeArea())
        .navigationTitle(embeddedInHome ? "" : "路线")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(embeddedInHome ? .hidden : .visible, for: .navigationBar)
        .navigationBarHidden(embeddedInHome)
        .fileImporter(isPresented: $importing, allowedContentTypes: GPXFile.types) { result in
            importFile(result)
        }
        .alert("导入路线", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .task {
            await OfflineTileStore.prefetch(app.importedRoutes.map(\.points))
        }
        .onChange(of: app.importedRoutes.map(\.id)) { _, ids in
            if let revealedRouteID, !ids.contains(revealedRouteID) {
                self.revealedRouteID = nil
            }
        }
    }

    /// One sentence. The circular import control above is the only call to action.
    private var emptyState: some View {
        Text("还没有导入的路线")
            .font(SkyTheme.Font.headline)
            .foregroundStyle(SkyTheme.Color.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var routeList: some View {
        ScrollView {
            LazyVStack(spacing: SkyTheme.Spacing.related) {
                ForEach(app.importedRoutes) { route in
                    RouteSwipeCard(
                        route: route,
                        selected: draft.routeID == route.id,
                        revealedID: $revealedRouteID,
                        onDelete: { delete(route) }
                    )
                }
            }
            .padding(.horizontal, SkyTheme.Spacing.screenInset)
            .padding(.bottom, SkyTheme.Spacing.screenInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func delete(_ route: SavedRoute) {
        if draft.routeID == route.id {
            draft.routeID = PlannedRoute.free.id
        }
        if revealedRouteID == route.id {
            revealedRouteID = nil
        }
        app.deleteRoute(id: route.id)
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            importError = "没有打开文件。"
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                importError = "这个文件里没有路线点。"
                return
            }
            let parsed = GPXFile.parse(data)
            guard !parsed.isEmpty else {
                importError = "这个文件里没有路线点。"
                return
            }
            let identifiers = app.addGPXRoutes(parsed, source: data)
            if identifiers.isEmpty {
                importError = "这个文件里没有路线点。"
            }
        }
    }
}

/// Circular primary control. The drawn circle is 36pt; the hit target stays 44pt.
private struct RouteImportButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SkyTheme.Color.onPrimary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(RouteImportButtonStyle())
        .accessibilityLabel("导入 GPX")
    }
}

private struct RouteImportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? SkyTheme.Color.primaryPressed : SkyTheme.Color.primary,
                in: Circle()
            )
            .frame(width: SkyTheme.Spacing.touchMin, height: SkyTheme.Spacing.touchMin, alignment: .trailing)
            .contentShape(Rectangle())
    }
}

private struct RouteSwipeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Same reveal width as the record list, so the red 删除 control matches that card.
private enum RouteSwipeMetrics {
    static let buttonWidth: CGFloat = 72
    static let gap: CGFloat = SkyTheme.Spacing.related
    static var revealed: CGFloat { buttonWidth + gap }
}

/// Slides a route card left to reveal 删除. Releasing only opens or closes that button.
/// The pan does not begin for a vertical or diagonal move, so the list scroll keeps that touch.
private struct RouteSwipeCard: View {
    var route: SavedRoute
    var selected: Bool
    @Binding var revealedID: String?
    var onDelete: () -> Void

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
        NavigationLink(value: MapRoute.detail(route.id)) {
            RouteSummaryCard(route: route, selected: selected)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!suppressNavigation && offset == 0)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: RouteSwipeHeightKey.self, value: geo.size.height)
            }
        }
        .offset(x: offset)
        .background(alignment: .trailing) {
            deleteButton
        }
        .overlay {
            if offset != 0 {
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                    Color.clear
                        .frame(width: RouteSwipeMetrics.revealed)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if deleteArmed {
                Color.clear
                    .frame(width: RouteSwipeMetrics.buttonWidth, height: rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onDelete() }
                    .accessibilityLabel("删除")
            }
        }
        .contentShape(Rectangle())
        // Attach the representable with gesture(_:). simultaneousGesture would fight the scroll.
        .gesture(deletePan)
        .accessibilityAction(named: Text("删除")) {
            onDelete()
        }
        .onPreferenceChange(RouteSwipeHeightKey.self) { height in
            if height > 0, height != rowHeight {
                rowHeight = height
            }
        }
        .onChange(of: revealedID) { _, id in
            guard id != route.id, offset != 0 else { return }
            close()
        }
    }

    private var deleteButton: some View {
        Text("删除")
            .font(SkyTheme.Font.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(SkyTheme.Color.onPrimary)
            .frame(width: RouteSwipeMetrics.buttonWidth)
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
                suppressNavigation = true
                revealedID = route.id
            },
            onChanged: { translation in
                let next = dragBase + translation
                offset = min(0, max(-RouteSwipeMetrics.revealed, next))
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
                    revealed: Double(RouteSwipeMetrics.revealed)
                )
                let open = resting < 0
                withAnimation(snap) {
                    offset = CGFloat(resting)
                }
                if open {
                    revealedID = route.id
                } else if revealedID == route.id {
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
        if revealedID == route.id {
            revealedID = nil
        }
    }
}

/// Same measurements as a record card. The track sits in that box and does not add height.
private enum RouteCardLayout {
    static let track: CGFloat = 84
    static let corner: CGFloat = 20
    static let horizontalInset: CGFloat = SkyTheme.Spacing.cardPadding
    static let verticalInset: CGFloat = 10
    static let rowSpacing: CGFloat = 4
}

private struct RouteSummaryCard: View {
    var route: SavedRoute
    var selected: Bool

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RouteCardLayout.corner, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if route.points.count >= 2 {
                RecordTrackLine(points: route.points)
                    .frame(width: RouteCardLayout.track, height: RouteCardLayout.track)
                    .padding(.trailing, RouteCardLayout.horizontalInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: RouteCardLayout.rowSpacing) {
                nameRow
                Text(RouteCardText.imported(route))
                    .font(SkyTheme.Font.footnote)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    metric(RouteCardText.distance(route.points), SkyTheme.Color.Metric.distance)
                    metric(RouteCardText.climb(route.points), SkyTheme.Color.Metric.elevation)
                }
                Text(RouteCardText.creator(route))
                    .font(SkyTheme.Font.footnote)
                    .foregroundStyle(SkyTheme.Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, RouteCardLayout.horizontalInset)
            .padding(.vertical, RouteCardLayout.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SkyTheme.Color.recordCard, in: cardShape)
        .clipShape(cardShape)
        .overlay {
            if selected {
                cardShape.strokeBorder(SkyTheme.Color.primary, lineWidth: 1.5)
            }
        }
        .shadow(
            color: SkyTheme.Shadow.card.color.opacity(SkyTheme.Shadow.card.opacity),
            radius: SkyTheme.Shadow.card.radius,
            y: SkyTheme.Shadow.card.y
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }

    private var nameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: SkyTheme.Spacing.related) {
            Text(route.name)
                .font(SkyTheme.Font.headline)
                .fontWeight(.bold)
                .foregroundStyle(SkyTheme.Color.ink)
                .lineLimit(1)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SkyTheme.Color.primary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func metric(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(SkyTheme.Font.headline)
            .fontWeight(.bold)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var accessibilitySummary: String {
        var parts = [
            route.name,
            RouteCardText.imported(route),
            "距离 \(RouteCardText.distance(route.points))",
            "爬升 \(RouteCardText.climb(route.points))",
            RouteCardText.creator(route)
        ]
        if selected {
            parts.append("已用于训练")
        }
        return parts.joined(separator: "，")
    }
}

private enum RouteCardDate {
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private enum RouteCardText {
    static func imported(_ route: SavedRoute) -> String {
        guard let importedAt = route.importedAt else { return "—" }
        return RouteCardDate.string(from: importedAt)
    }

    static func distance(_ points: [GeoPoint]) -> String {
        "\(Format.kilometers(RouteStats.distance(points)))公里"
    }

    static func climb(_ points: [GeoPoint]) -> String {
        "\(Int(RouteStats.ascent(points).rounded()))米"
    }

    static func creator(_ route: SavedRoute) -> String {
        "创建人 \(route.creatorLabel)"
    }
}

struct RouteDetailView: View {
    @EnvironmentObject private var app: PhoneAppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tileStatus = TileCacheStatus.shared

    var routeID: String
    @State private var zoomArmed = false
    @State private var multiplier = 1.0
    @State private var zoomDragBase: Double?
    @State private var showsChart = false
    @State private var factPage: Int? = 0
    @State private var showsKilometerMarkers = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var editTarget: RouteFactEditTarget?
    /// Height of the floating card, including the home-indicator padding, so the tools sit above it.
    @State private var chromeHeight: CGFloat = 220
    /// UIKit's latest title string. A class so keystrokes do not re-render the field and move the caret.
    @State private var titleBuffer = RouteTitleBuffer()
    @FocusState private var titleFocused: Bool

    private var route: SavedRoute? {
        app.importedRoutes.first { $0.id == routeID }
    }

    var body: some View {
        GeometryReader { geo in
            // The reader sits in the safe area. Add the insets back so the split is a fraction of the full screen.
            let top = geo.safeAreaInsets.top
            let bottom = geo.safeAreaInsets.bottom
            let screenHeight = geo.size.height + top + bottom
            Group {
                if let route {
                    detail(route, screenHeight: screenHeight, topInset: top, bottomInset: bottom)
                } else {
                    missing
                }
            }
            .frame(width: geo.size.width, height: screenHeight, alignment: .top)
            .padding(.top, -top)
            .padding(.bottom, -bottom)
        }
        .ignoresSafeArea(.keyboard)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func detail(_ route: SavedRoute, screenHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let layout = RouteCheckpoints.layout(waypoints: route.waypoints, points: route.points)
        let marks = layout.marks.map { mark in
            var copy = mark
            copy.name = RouteFacts.markName(mark, route: route)
            return copy
        }
        let shown = RouteCheckpointLayout(marks: marks, segments: layout.segments)
        return ZStack(alignment: .bottom) {
            mapColumn(route, layout: shown, topInset: topInset, legalBottomInset: chromeHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            floatingChrome(route, bottomInset: bottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: screenHeight, alignment: .top)
        .background(Color(red: 0.886, green: 0.925, blue: 0.910))
        .onAppear { tileStatus.refresh(for: route.points) }
        .task(id: route.id) {
            tileStatus.refresh(for: route.points)
            await OfflineTileStore.prefetch([route.points])
            tileStatus.refresh(for: route.points)
        }
        .onChange(of: route.id) { _, _ in
            factPage = 0
        }
        .onChange(of: editingTitle) { _, editing in
            guard editing else { return }
            Task { @MainActor in
                if editingTitle { titleFocused = true }
            }
        }
        .onChange(of: titleFocused) { _, focused in
            // A tap beside the field often only resigns it. The button action never runs.
            // Commit on the next turn, after textDidEndEditing has filled the buffer.
            guard !focused else { return }
            Task { @MainActor in
                guard editingTitle else { return }
                commitTitle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification)) { note in
            guard editingTitle, let field = note.object as? UITextField else { return }
            titleBuffer.text = RouteTitleField.shownText(in: field)
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { note in
            guard editingTitle, let field = note.object as? UITextField else { return }
            titleBuffer.text = RouteTitleField.shownText(in: field)
        }
        .onDisappear { commitTitle() }
        .onPreferenceChange(RouteChromeHeightKey.self) { height in
            guard height > 1, abs(height - chromeHeight) > 0.5 else { return }
            chromeHeight = height
        }
        .sheet(item: $editTarget) { target in
            RouteFactEditSheet(routeID: routeID, target: target)
        }
    }

    private func mapColumn(
        _ route: SavedRoute,
        layout: RouteCheckpointLayout,
        topInset: CGFloat,
        legalBottomInset: CGFloat
    ) -> some View {
        let markerCount = RouteKilometers.markers(along: route.points).count
        return ZStack {
            OfflineRouteMap(
                routeID: route.id,
                points: route.points,
                checkpoints: layout.marks,
                showsKilometerMarkers: showsKilometerMarkers,
                zoomMultiplier: multiplier,
                zoomArmed: zoomArmed,
                tileEpoch: tileStatus.revision,
                legalBottomInset: legalBottomInset,
                onZoomChanged: { value in
                    guard !zoomArmed else { return }
                    multiplier = value
                },
                onZoomDrag: { phase in
                    handleZoomDrag(phase)
                }
            )
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            titleBar(route, topInset: topInset)
        }
        .overlay(alignment: .bottomTrailing) {
            toolColumn(markerCount: markerCount)
                .padding(.trailing, 12)
                .padding(.bottom, legalBottomInset + 8)
        }
    }

    private func titleBar(_ route: SavedRoute, topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if editingTitle {
                titleCapsule(route)
            } else {
                HStack(spacing: 0) {
                    titleCapsule(route)
                    Spacer(minLength: 0)
                }
            }
            Text(tileStatus.note)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.92), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.top, topInset + 8)
    }

    /// System text field: the caret, delete, and the copy / paste / cut menu stay the platform ones.
    private func titleCapsule(_ route: SavedRoute) -> some View {
        HStack(spacing: 4) {
            RouteTitleIconButton(
                systemName: "chevron.left",
                pointSize: 17,
                tint: Color.omniInk,
                accessibilityLabel: "返回"
            ) {
                commitTitle()
                dismiss()
            }
            .frame(width: 36, height: 40)
            if editingTitle {
                TextField(
                    "路线名称",
                    text: $titleDraft,
                    prompt: Text("路线名称").foregroundStyle(Color.omniMuted)
                )
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit(commitTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.omniInk)
                .tint(SkyTheme.Color.primary)
                .lineLimit(1)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("路线名称")
            } else {
                Text(route.name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.omniInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            RouteTitleIconButton(
                systemName: editingTitle ? "square.and.arrow.down" : "pencil",
                pointSize: 15,
                tint: editingTitle ? SkyTheme.Color.primary : Color.omniInk,
                accessibilityLabel: editingTitle ? "保存" : "编辑路线名称"
            ) {
                if editingTitle {
                    commitTitle()
                } else {
                    beginTitleEdit(route)
                }
            }
            .frame(width: 36, height: 40)
            .layoutPriority(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .background(Color.white.opacity(0.92), in: Capsule())
    }

    private func beginTitleEdit(_ route: SavedRoute) {
        titleDraft = route.name
        titleBuffer.text = route.name
        editingTitle = true
    }

    /// Done and save both commit. A cleared field keeps the previous title.
    ///
    /// The save control used to read `titleDraft` and then remove the field in the same turn.
    /// UIKit writes that binding when editing ends, which is after a neighbor's action — and a
    /// SwiftUI button beside a focused field often never receives the tap. `renameRoute` then
    /// sees the old name and does not write. Read the live field, or the last text UIKit posted,
    /// before leaving edit mode.
    private func commitTitle() {
        guard editingTitle else { return }
        let typed = RouteTitleField.liveText() ?? titleBuffer.text ?? titleDraft
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTitle = false
        titleFocused = false
        guard !trimmed.isEmpty else { return }
        titleDraft = trimmed
        app.renameRoute(id: routeID, name: trimmed)
    }

    /// Glass card over the map. The altitude chart takes the same slot as the fact pager.
    private func floatingChrome(_ route: SavedRoute, bottomInset: CGFloat) -> some View {
        Group {
            if showsChart {
                ElevationProfileChart(route: route)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .routeGlassCard()
            } else {
                routeFactPager(route)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, bottomInset + 8)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: RouteChromeHeightKey.self, value: geo.size.height)
            }
        }
    }

    private func factPages(_ route: SavedRoute) -> [RouteFactPage] {
        RouteFacts.cards(for: route).enumerated().map { offset, card in
            RouteFactPage(id: offset, card: card)
        }
    }

    /// Totals, then one card per real waypoint, then 终点 when the last waypoint is short of the track end.
    private func routeFactPager(_ route: SavedRoute) -> some View {
        let pages = factPages(route)
        let showsIndicator = pages.count > 1
        return VStack(spacing: 6) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages) { page in
                        factCard(page, route: route)
                            .containerRelativeFrame(.horizontal)
                            .id(page.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $factPage, anchor: .leading)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollEdgeEffectHidden(true, for: .horizontal)
            .frame(height: 172)
            .accessibilityHint(showsIndicator ? "左右滑动查看各点" : "")
            if showsIndicator {
                factPageIndicator(count: pages.count)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .routeGlassCard()
    }

    private func factCard(_ page: RouteFactPage, route: SavedRoute) -> some View {
        ViewThatFits(in: .vertical) {
            factStack(page, route: route, title: 16, label: 12, value: 15, spacing: 3)
            factStack(page, route: route, title: 13, label: 11, value: 13, spacing: 1)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { openEditor(page) })
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { openEditor(page) }
        .accessibilityHint("编辑这张卡片")
    }

    private func openEditor(_ page: RouteFactPage) {
        switch page.card {
        case .totals:
            editTarget = .totals
        case .waypoint(let progress):
            editTarget = .waypoint(progress.id)
        case .finish:
            editTarget = .finish
        }
    }

    private func factStack(
        _ page: RouteFactPage,
        route: SavedRoute,
        title: CGFloat,
        label: CGFloat,
        value: CGFloat,
        spacing: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            switch page.card {
            case .totals:
                let totals = RouteFacts.displayTotals(route)
                Text("总数据")
                    .font(.system(size: title, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.Color.ink)
                    .lineLimit(1)
                factMetric("导入时间", importTime(route), SkyTheme.Color.ink, label: label, valueSize: value)
                HStack(alignment: .top, spacing: 10) {
                    factMetric("距离", routeKilometers(totals.distanceMeters), SkyTheme.Color.Metric.distance, label: label, valueSize: value)
                    factMetric("爬升", routeMeters(totals.ascentMeters), SkyTheme.Color.Metric.elevation, label: label, valueSize: value)
                }
                HStack(alignment: .top, spacing: 10) {
                    factMetric("下降", routeMeters(totals.descentMeters), SkyTheme.Color.Metric.elevation, label: label, valueSize: value)
                    factMetric(
                        "最高海拔",
                        totals.maxElevationMeters.map(routeMeters) ?? "—",
                        SkyTheme.Color.Metric.elevation,
                        label: label,
                        valueSize: value
                    )
                }
                factMetric("创建人", route.creatorLabel, SkyTheme.Color.ink, label: label, valueSize: value)
            case .waypoint(let progress):
                checkpointFacts(
                    RouteFacts.displayWaypoint(progress, route: route),
                    title: title,
                    label: label,
                    value: value,
                    spacing: spacing
                )
            case .finish(let finish):
                checkpointFacts(
                    RouteFacts.displayFinish(finish, route: route),
                    title: title,
                    label: label,
                    value: value,
                    spacing: spacing
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shared body of a waypoint card and the finish card. The title is the display name; 终点 does not rename.
    private func checkpointFacts(
        _ shown: RouteFacts.Waypoint,
        title: CGFloat,
        label: CGFloat,
        value: CGFloat,
        spacing: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shown.name)
                    .font(.system(size: title, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Text(RouteFacts.cutoffLabel(shown.cutoff))
                    .font(.system(size: value, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .combine)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: spacing) {
                    factMetric("距离", routeKilometers(shown.segmentDistanceMeters), SkyTheme.Color.Metric.distance, label: label, valueSize: value)
                    factMetric("爬升", routeMeters(shown.segmentAscentMeters), SkyTheme.Color.Metric.elevation, label: label, valueSize: value)
                    factMetric("下降", routeMeters(shown.segmentDescentMeters), SkyTheme.Color.Metric.elevation, label: label, valueSize: value)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: spacing) {
                    factMetric("累积距离", routeKilometers(shown.cumulativeDistanceMeters), SkyTheme.Color.Metric.distance, label: label, valueSize: value)
                    factMetric("累积爬升", routeMeters(shown.cumulativeAscentMeters), SkyTheme.Color.Metric.elevation, label: label, valueSize: value)
                    factMetric("累积下降", routeMeters(shown.cumulativeDescentMeters), SkyTheme.Color.Metric.elevation, label: label, valueSize: value)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func factPageIndicator(count: Int) -> some View {
        let current = min(max(factPage ?? 0, 0), count - 1)
        return Group {
            if count > 12 {
                Text("\(current + 1)/\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(SkyTheme.Color.secondary)
            } else {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { index in
                        Circle()
                            .fill(index == current ? SkyTheme.Color.primary : SkyTheme.Color.tertiary)
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(current + 1) 页，共 \(count) 页")
    }

    /// Label above the figure. The number and its unit share one color and one weight.
    private func factMetric(
        _ title: String,
        _ value: String,
        _ valueColor: Color,
        label: CGFloat,
        valueSize: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: label, weight: .medium, design: .rounded))
                .foregroundStyle(SkyTheme.Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: valueSize, weight: .bold, design: .rounded))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Word joiner keeps the digits and × on one line. The armed label may draw wider than the 42pt column.
    private var zoomScaleText: String {
        String(format: "%.1f", multiplier) + "\u{2060}×"
    }

    /// Vertical drag handle shown only while the magnifier is armed. Same scale math as the map drag.
    /// The column stays 42×128. The label sizes to the text, so a tight width cannot wrap × onto a second line.
    private var zoomScaleLine: some View {
        ZStack {
            Capsule()
                .fill(SkyTheme.Color.primary)
                .frame(width: 2, height: 128)
            Text(zoomScaleText)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(SkyTheme.Color.ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(SkyTheme.Color.card.opacity(0.94), in: Capsule())
                .fixedSize(horizontal: true, vertical: true)
        }
        .frame(width: 42, height: 128)
        .contentShape(Rectangle())
        .gesture(zoomSlide)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("缩放倍数")
        .accessibilityValue(String(format: "%.1f倍", multiplier))
        .accessibilityHint("上下滑动调整比例")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                multiplier = min(16, multiplier * 1.25)
            case .decrement:
                multiplier = max(0.4, multiplier / 1.25)
            @unknown default:
                break
            }
        }
    }

    private var zoomSlide: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if zoomDragBase == nil {
                    handleZoomDrag(.began)
                }
                handleZoomDrag(.changed(value.translation.height))
            }
            .onEnded { _ in
                handleZoomDrag(.ended)
            }
    }

    private func toolColumn(markerCount: Int) -> some View {
        VStack(spacing: 10) {
            if zoomArmed {
                zoomScaleLine
            }
            if showsKilometerMarkers, markerCount == 0 {
                Text("不足 1 公里，没有路程点")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.92), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
            }
            toolButton(
                system: "plus.magnifyingglass",
                label: "缩放",
                hint: zoomArmed ? "再点一次结束滑动" : "点按后上下滑动调整比例",
                active: zoomArmed,
                title: zoomArmed ? nil : zoomScaleText
            ) {
                zoomDragBase = nil
                zoomArmed.toggle()
            }
            .accessibilityValue(String(format: "%.1f倍", multiplier))
            toolButton(
                system: "chart.xyaxis.line",
                label: "海拔分析",
                hint: "在轨迹数据和海拔剖面之间切换",
                active: showsChart,
                tinted: true
            ) {
                showsChart.toggle()
            }
            .accessibilityValue(showsChart ? "海拔" : "轨迹数据")
            toolButton(
                system: showsKilometerMarkers ? "smallcircle.filled.circle.fill" : "smallcircle.filled.circle",
                label: "路程点",
                hint: "沿路线显示每公里的标记",
                active: showsKilometerMarkers,
                tinted: true
            ) {
                showsKilometerMarkers.toggle()
            }
            .accessibilityValue(kilometerValue(markerCount))
        }
    }

    private func kilometerValue(_ markerCount: Int) -> String {
        guard showsKilometerMarkers else { return "未显示" }
        if markerCount == 0 { return "不足 1 公里，没有路程点" }
        return "已显示"
    }

    private func toolButton(
        system: String,
        label: String,
        hint: String,
        active: Bool,
        tinted: Bool = false,
        title: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let foreground = active ? (tinted ? SkyTheme.Color.primary : Color.white) : Color.omniInk
        let fill = active ? (tinted ? SkyTheme.Color.recordCard : Color.omniCobalt) : Color.white
        return Button(action: action) {
            Group {
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Image(systemName: system)
                        .font(.system(size: 18, weight: .semibold))
                }
            }
            .foregroundStyle(foreground)
            .frame(width: 42, height: 42)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func handleZoomDrag(_ phase: ZoomDragPhase) {
        switch phase {
        case .began:
            zoomDragBase = multiplier
        case .changed(let translation):
            let base = zoomDragBase ?? multiplier
            let scale = exp(Double(-translation) / 280)
            multiplier = min(16, max(0.4, base * scale))
        case .ended:
            zoomDragBase = nil
        }
    }

    private var missing: some View {
        VStack(spacing: 12) {
            Text("这条路线不在了")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Button("返回") { dismiss() }
                .font(.system(size: 16, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBackground())
    }
}

/// Last title UIKit reported. Held by reference so writing it does not rebuild the text field.
private final class RouteTitleBuffer {
    var text: String?
}

/// Reads the system text field that is actually editing. The SwiftUI binding can lag that field.
private enum RouteTitleField {
    static func shownText(in field: UITextField) -> String {
        let raw = field.text ?? ""
        guard let marked = field.markedTextRange else { return raw }
        let start = field.offset(from: field.beginningOfDocument, to: marked.start)
        let end = field.offset(from: field.beginningOfDocument, to: marked.end)
        let ns = raw as NSString
        guard start >= 0, end >= start, end <= ns.length else { return raw }
        return ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: "")
    }

    static func liveText() -> String? {
        guard let field = firstField() else { return nil }
        return shownText(in: field)
    }

    private static func firstField() -> UITextField? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let windows = scene.windows
            var ordered: [UIWindow] = []
            ordered.append(contentsOf: windows.filter(\.isKeyWindow))
            ordered.append(contentsOf: windows.filter { !$0.isKeyWindow })
            for window in ordered {
                guard let hit = window.firstResponderView() else { continue }
                var view: UIView? = hit
                while let current = view {
                    if let field = current as? UITextField { return field }
                    view = current.superview
                }
            }
        }
        return nil
    }
}

private extension UIView {
    func firstResponderView() -> UIView? {
        if isFirstResponder { return self }
        for child in subviews {
            if let found = child.firstResponderView() { return found }
        }
        return nil
    }
}

/// UIKit button. A SwiftUI button next to a focused text field often only resigns the keyboard.
private struct RouteTitleIconButton: UIViewRepresentable {
    var systemName: String
    var pointSize: CGFloat
    var tint: Color
    var accessibilityLabel: String
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        button.backgroundColor = .clear
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        let symbol = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let image = UIImage(systemName: systemName, withConfiguration: symbol)
        var config = UIButton.Configuration.plain()
        config.image = image
        config.baseForegroundColor = UIColor(tint)
        config.background.backgroundColor = .clear
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        button.configuration = config
        button.removeTarget(nil, action: nil, for: .touchUpInside)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        button.accessibilityLabel = accessibilityLabel
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: 36, height: 40)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}

private struct RouteChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// Translucent card over the map. Not a solid white or pale-blue panel.
    func routeGlassCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous)
        return background(.thinMaterial, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.55), lineWidth: 0.6) }
            .shadow(color: Color.black.opacity(0.18), radius: 16, y: 8)
    }
}

private struct RouteFactPage: Identifiable {
    var id: Int
    var card: RouteDetailCard
}

private struct PlotWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ElevationProfileChart: View {
    var route: SavedRoute
    @State private var plotWidth: CGFloat = 0

    private var points: [GeoPoint] { route.points }

    private var axisMarks: [ElevationAxisMark] {
        ElevationProfileAxis.marks(for: route)
    }

    private var samples: [RouteAltitudeSample] {
        // Every stored point, so the profile uses the same altitudes as the colored track.
        RouteStats.altitudeProfile(points, limit: max(points.count, 2))
    }

    private var bounds: (low: Double, high: Double)? {
        ElevationScale.bounds(points)
    }

    private var flat: Bool {
        guard let bounds else { return true }
        return bounds.high - bounds.low < ElevationScale.flatSpanMeters
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("海拔")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.omniInk)
                Spacer(minLength: 8)
                if let bounds {
                    Text("\(meterText(bounds.low))–\(meterText(bounds.high)) 米")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.omniMuted)
                        .lineLimit(1)
                }
            }
            Text(flat ? "海拔几乎没有变化" : "低处绿色，高处红色")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniMuted)
            if samples.count < 2 || bounds == nil {
                Text("点数不够，画不出曲线")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let bounds {
                profile(low: bounds.low, high: bounds.high)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 64)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)
                distanceAxis
            }
        }
        .padding(.horizontal, SkyTheme.Spacing.screenInset)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(height: chartHeight)
    }

    /// Ticks and short names sit under the curve, on the same distance scale, and leave 0 / total in place.
    private var distanceAxis: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !axisMarks.isEmpty {
                tickBand
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("0")
                Spacer(minLength: 8)
                Text("\(distanceLabel) 公里")
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.trailing, 50)
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.omniMuted)
        .accessibilityHidden(true)
    }

    private var tickBand: some View {
        Canvas { context, size in
            let placed = placedLabels(plotWidth: size.width)
            for item in placed {
                let tickX = axisX(item.tickFraction, width: size.width)
                var tick = Path()
                tick.move(to: CGPoint(x: tickX, y: 0))
                tick.addLine(to: CGPoint(x: tickX, y: 5))
                context.stroke(tick, with: .color(Color.omniMuted), style: StrokeStyle(lineWidth: 1))
                let label = Text(item.name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
                let resolved = context.resolve(label)
                let center = axisX(item.labelFraction, width: size.width)
                resolved.draw(
                    at: CGPoint(x: center, y: 7 + CGFloat(item.lane) * 14 + 6),
                    anchor: .center
                )
            }
        }
        .frame(height: tickBandHeight)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: PlotWidthKey.self, value: geo.size.width)
            }
        }
        .onPreferenceChange(PlotWidthKey.self) { plotWidth = $0 }
    }

    private var chartHeight: CGFloat {
        let ticks = (samples.count >= 2 && bounds != nil) ? tickBandHeight : 0
        return 172 + ticks
    }

    private var tickBandHeight: CGFloat {
        guard !axisMarks.isEmpty else { return 0 }
        return 7 + CGFloat(laneCount) * 14
    }

    private var laneCount: Int {
        guard !axisMarks.isEmpty else { return 0 }
        let placed = placedLabels(plotWidth: plotWidth > 1 ? plotWidth : 1)
        return (placed.map(\.lane).max() ?? 0) + 1
    }

    private func placedLabels(plotWidth: CGFloat) -> [ElevationAxisLabel] {
        ElevationProfileAxis.labels(
            axisMarks,
            plotWidth: Double(plotWidth),
            labelWidth: Self.estimatedLabelWidth
        )
    }

    /// Same inset the curve uses, so a tick lands on that waypoint's distance.
    private func axisX(_ fraction: Double, width: CGFloat) -> CGFloat {
        let inner = max(width - 2, 1)
        return 1 + CGFloat(min(1, max(0, fraction))) * inner
    }

    private static func estimatedLabelWidth(_ name: String) -> Double {
        Double(max(name.count, 1)) * 10
    }

    private func profile(low: Double, high: Double) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Canvas { context, size in
                draw(context: context, size: size, low: low, high: high)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .trailing) {
                Text(meterText(high))
                Spacer(minLength: 0)
                Text(meterText((low + high) / 2))
                Spacer(minLength: 0)
                Text(meterText(low))
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.omniMuted)
            .frame(width: 44)
        }
    }

    /// The canvas height is this route's altitude range, so a vertical green→yellow→red
    /// gradient is the same scale the map uses for each point.
    private func draw(context: GraphicsContext, size: CGSize, low: Double, high: Double) {
        let rect = CGRect(x: 1, y: 3, width: max(size.width - 2, 1), height: max(size.height - 6, 1))
        let span = high - low
        let flatLine = span < ElevationScale.flatSpanMeters
        func yPos(_ altitude: Double) -> CGFloat {
            if flatLine { return rect.midY }
            let unit = min(1, max(0, (altitude - low) / span))
            return rect.maxY - CGFloat(unit) * rect.height
        }
        let total = max(samples.last?.distanceKilometers ?? 0, 0.000001)
        func xPos(_ kilometers: Double) -> CGFloat {
            rect.minX + CGFloat(min(1, max(0, kilometers / total))) * rect.width
        }
        var line = Path()
        for (index, sample) in samples.enumerated() {
            let point = CGPoint(x: xPos(sample.distanceKilometers), y: yPos(sample.altitudeMeters))
            if index == 0 {
                line.move(to: point)
            } else {
                line.addLine(to: point)
            }
        }
        guard let first = samples.first, let last = samples.last else { return }
        var fill = line
        fill.addLine(to: CGPoint(x: xPos(last.distanceKilometers), y: rect.maxY))
        fill.addLine(to: CGPoint(x: xPos(first.distanceKilometers), y: rect.maxY))
        fill.closeSubpath()
        context.fill(fill, with: shading(in: rect, flatLine: flatLine, opacity: 0.78))
        context.stroke(
            line,
            with: shading(in: rect, flatLine: flatLine, opacity: 1),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
        )
    }

    private func shading(in rect: CGRect, flatLine: Bool, opacity: Double) -> GraphicsContext.Shading {
        if flatLine {
            return .color(elevationColor(unit: 0.5).opacity(opacity))
        }
        return .linearGradient(
            Gradient(stops: [
                .init(color: elevationColor(unit: 1).opacity(opacity), location: 0),
                .init(color: elevationColor(unit: 0.5).opacity(opacity), location: 0.5),
                .init(color: elevationColor(unit: 0).opacity(opacity), location: 1)
            ]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
        )
    }

    private func elevationColor(unit: Double) -> Color {
        let rgb = ElevationScale.rgb(unit: unit)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private var distanceLabel: String {
        Format.kilometers((samples.last?.distanceKilometers ?? 0) * 1000)
    }

    private var accessibilityText: String {
        guard let bounds else { return "海拔剖面" }
        let base = "海拔剖面，最低 \(meterText(bounds.low)) 米，最高 \(meterText(bounds.high)) 米"
        let names = axisMarks.map(\.name)
        guard !names.isEmpty else { return base }
        return base + "，路点 " + names.joined(separator: "、")
    }

    private func meterText(_ meters: Double) -> String {
        String(Int(meters.rounded()))
    }
}

private func importTime(_ route: SavedRoute) -> String {
    guard let importedAt = route.importedAt else { return "—" }
    return Format.dayTime(importedAt)
}

private func routeKilometers(_ meters: Double) -> String {
    "\(Format.kilometers(meters)) 公里"
}

private func routeMeters(_ meters: Double) -> String {
    "\(Int(meters.rounded())) 米"
}
