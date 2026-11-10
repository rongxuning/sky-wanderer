import Charts
import SwiftUI
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
    /// Home tab keeps this list and drops the navigation title.
    var embeddedInHome: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if embeddedInHome, !app.importedRoutes.isEmpty {
                HStack {
                    Button {
                        importing = true
                    } label: {
                        Text("导入")
                            .font(SkyTheme.Font.callout)
                            .foregroundStyle(SkyTheme.Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("导入 GPX")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
            Group {
                if app.importedRoutes.isEmpty {
                    emptyState
                } else {
                    routeList
                }
            }
        }
        .background {
            if embeddedInHome {
                SkyTheme.Color.grouped
            } else {
                CanvasBackground()
            }
        }
        .navigationTitle(embeddedInHome ? "" : "路线")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(embeddedInHome ? .hidden : .visible, for: .navigationBar)
        .navigationBarHidden(embeddedInHome)
        .toolbar {
            if !embeddedInHome {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入") { importing = true }
                        .accessibilityLabel("导入 GPX")
                }
            }
        }
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
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("还没有导入的路线")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniInk)
            Text("选择一个 GPX 文件，路线会留在这台手机上。")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniMuted)
                .multilineTextAlignment(.center)
            Button {
                importing = true
            } label: {
                Text("导入 GPX")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.omniCobalt)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var routeList: some View {
        List {
            ForEach(app.importedRoutes) { route in
                NavigationLink(value: MapRoute.detail(route.id)) {
                    RouteRow(route: route, selected: draft.routeID == route.id)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("删除", role: .destructive) {
                        if draft.routeID == route.id {
                            draft.routeID = PlannedRoute.free.id
                        }
                        app.deleteRoute(id: route.id)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            Text("地图会缓存在这台手机上，没有网络也能看。")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniMuted)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

private struct RouteRow: View {
    var route: SavedRoute
    var selected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RouteSketch(points: route.points)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(route.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.omniInk)
                    .lineLimit(1)
                Text("导入时间 \(importTime(route))")
                    .foregroundStyle(Color.omniMuted)
                Text("距离 \(routeKilometers(RouteStats.distance(route.points)))")
                    .foregroundStyle(Color.omniInk)
                Text("爬升 \(routeMeters(RouteStats.ascent(route.points)))")
                    .foregroundStyle(Color.omniInk)
                Text("创建人 \(route.creatorLabel)")
                    .foregroundStyle(Color.omniInk)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.omniCobalt)
                    .accessibilityLabel("已用于训练")
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? Color.omniCobalt : Color.black.opacity(0.06), lineWidth: selected ? 1.5 : 1)
        )
        .accessibilityElement(children: .combine)
    }
}

struct RouteSketch: View {
    var points: [GeoPoint]

    var body: some View {
        Canvas { context, size in
            guard let first = points.first else { return }
            if points.count == 1 {
                let dot = CGRect(x: size.width / 2 - 3, y: size.height / 2 - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: dot), with: .color(Color.omniCobalt))
                return
            }
            let midLatitude = points.map(\.latitude).reduce(0, +) / Double(points.count)
            let cosLat = cos(midLatitude * .pi / 180)
            let east = points.map { ($0.longitude - first.longitude) * 111_320 * cosLat }
            let north = points.map { ($0.latitude - first.latitude) * 111_320 }
            let minX = east.min() ?? 0
            let maxX = east.max() ?? 0
            let minY = north.min() ?? 0
            let maxY = north.max() ?? 0
            let spanX = max(maxX - minX, 1)
            let spanY = max(maxY - minY, 1)
            let pad: CGFloat = 8
            let width = max(size.width - pad * 2, 1)
            let height = max(size.height - pad * 2, 1)
            let scale = min(width / spanX, height / spanY)
            let usedW = spanX * scale
            let usedH = spanY * scale
            let originX = pad + (width - usedW) / 2
            let originY = pad + (height - usedH) / 2
            var path = Path()
            for index in points.indices {
                let x = originX + (east[index] - minX) * scale
                let y = originY + (maxY - north[index]) * scale
                let point = CGPoint(x: x, y: y)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            context.stroke(
                path,
                with: .color(Color.omniCobalt),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
        .background(SkyHomeColor.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct RouteDetailView: View {
    @EnvironmentObject private var app: PhoneAppState
    @EnvironmentObject private var draft: WorkoutDraft
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tileStatus = TileCacheStatus.shared

    var routeID: String
    @State private var zoomArmed = false
    @State private var multiplier = 1.0
    @State private var zoomDragBase: Double?
    @State private var showsChart = false
    @State private var showsKilometerMarkers = false

    private var route: SavedRoute? {
        app.importedRoutes.first { $0.id == routeID }
    }

    var body: some View {
        Group {
            if let route {
                detail(route)
            } else {
                missing
            }
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func detail(_ route: SavedRoute) -> some View {
        let layout = RouteCheckpoints.layout(waypoints: route.waypoints, points: route.points)
        return VStack(spacing: 0) {
            ZStack {
                OfflineRouteMap(
                    routeID: route.id,
                    points: route.points,
                    checkpoints: layout.marks,
                    showsKilometerMarkers: showsKilometerMarkers,
                    zoomMultiplier: multiplier,
                    zoomArmed: zoomArmed,
                    tileEpoch: tileStatus.revision,
                    onZoomChanged: { value in
                        guard !zoomArmed else { return }
                        multiplier = value
                    },
                    onZoomDrag: { phase in
                        handleZoomDrag(phase)
                    }
                )
                .ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.omniInk)
                                .frame(width: 40, height: 40)
                                .background(Color.white.opacity(0.92), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("返回")
                        Text(route.name)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.omniInk)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.92), in: Capsule())
                        Spacer(minLength: 0)
                    }
                    Text(tileStatus.note)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.omniInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.92), in: Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .overlay(alignment: .bottom) {
                // Equal 12pt side insets. Tools sit above the card and do not narrow it.
                VStack(alignment: .trailing, spacing: 10) {
                    toolColumn
                    Group {
                        if showsChart {
                            ElevationChangeChart(points: route.points, layout: layout)
                        } else {
                            infoPanel(route)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            elevationDock(route)
        }
        .background(Color.white)
        .onAppear { tileStatus.refresh(for: route.points) }
        .task(id: route.id) {
            tileStatus.refresh(for: route.points)
            await OfflineTileStore.prefetch([route.points])
            tileStatus.refresh(for: route.points)
        }
    }

    private func elevationDock(_ route: SavedRoute) -> some View {
        let markerCount = RouteKilometers.markers(along: route.points).count
        return VStack(alignment: .leading, spacing: 8) {
            ElevationProfileChart(points: route.points)
            kilometerControl(markerCount: markerCount)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func kilometerControl(markerCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showsKilometerMarkers.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showsKilometerMarkers ? "smallcircle.filled.circle.fill" : "smallcircle.filled.circle")
                        .font(.system(size: 16, weight: .semibold))
                    Text("路程点")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Spacer(minLength: 0)
                    Text(showsKilometerMarkers ? "已显示" : "未显示")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(showsKilometerMarkers ? SkyTheme.Color.onPrimary : SkyTheme.Color.ink)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    showsKilometerMarkers ? SkyTheme.Color.primary : SkyTheme.Color.grouped,
                    in: RoundedRectangle(cornerRadius: SkyTheme.Radius.chip, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("路程点")
            .accessibilityValue(showsKilometerMarkers ? "已显示" : "未显示")
            .accessibilityHint("沿路线显示每公里的标记")
            .accessibilityAddTraits(showsKilometerMarkers ? .isSelected : [])
            if showsKilometerMarkers, markerCount == 0 {
                Text("不足 1 公里，没有路程点")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
            }
        }
    }

    private var toolColumn: some View {
        VStack(spacing: 8) {
            if zoomArmed {
                Text(String(format: "%.1f×", multiplier))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.omniInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityLabel("缩放倍数")
                    .accessibilityValue(String(format: "%.1f倍", multiplier))
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
                Text("上下拖动")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.92), in: Capsule())
            }
            toolButton(system: "plus.magnifyingglass", label: "缩放", hint: "点按后上下拖动地图", active: zoomArmed) {
                zoomArmed.toggle()
            }
            toolButton(system: "chart.xyaxis.line", label: "海拔分析", hint: "查看海拔变化", active: showsChart) {
                showsChart.toggle()
            }
        }
    }

    private func infoPanel(_ route: SavedRoute) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RouteSketch(points: route.points)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                field("导入时间", importTime(route))
                field("距离", routeKilometers(RouteStats.distance(route.points)))
                field("爬升", routeMeters(RouteStats.ascent(route.points)))
                field("创建人", route.creatorLabel)
                field("最高海拔", maxElevationText(route.points))
                HStack(spacing: 12) {
                    Button(draft.routeID == route.id ? "已用于训练" : "用于训练") {
                        draft.routeID = route.id
                    }
                    .buttonStyle(.plain)
                    if draft.routeID == route.id {
                        Button("取消使用") {
                            draft.routeID = PlannedRoute.free.id
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.omniMuted)
                    }
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.omniCobalt)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .glass(radius: 22)
    }

    private func field(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(Color.omniMuted)
            Text(value)
                .foregroundStyle(Color.omniInk)
                .lineLimit(1)
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
    }

    private func toolButton(
        system: String,
        label: String,
        hint: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.omniInk)
                .frame(width: 44, height: 44)
                .background(active ? Color.omniCobalt : Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

private struct ElevationProfileChart: View {
    var points: [GeoPoint]

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
        VStack(alignment: .leading, spacing: 6) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 120)
            } else if let bounds {
                profile(low: bounds.low, high: bounds.high)
                    .frame(height: 128)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("0")
                    Spacer(minLength: 8)
                    Text("\(distanceLabel) 公里")
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.trailing, 50)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniMuted)
                .accessibilityHidden(true)
            }
        }
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
        return "海拔剖面，最低 \(meterText(bounds.low)) 米，最高 \(meterText(bounds.high)) 米"
    }

    private func meterText(_ meters: Double) -> String {
        String(Int(meters.rounded()))
    }
}

private struct ElevationChangeChart: View {
    var points: [GeoPoint]
    var layout: RouteCheckpointLayout

    private var samples: [ElevationSample] {
        RouteStats.profile(points)
    }

    private var marks: [RouteCheckpointMark] { layout.marks }

    private var segments: [RouteSegmentSummary] { layout.segments }

    private var flat: Bool {
        let values = samples.map(\.changeMeters)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        return high - low < 0.5
    }

    private var yDomain: ClosedRange<Double> {
        let values = samples.map(\.changeMeters) + marks.map(\.changeMeters)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        if high - low < 1 {
            return (low - 5)...(high + 5)
        }
        let pad = (high - low) * 0.18
        return (low - pad)...(high + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("海拔变化")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.omniInk)
            Text(flat ? "海拔几乎没有变化" : "横轴是距离，纵轴是相对起点的升降")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniMuted)
            if marks.isEmpty {
                Text("这条路线没有检查点")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
            }
            if samples.count < 2 {
                Text("点数不够，画不出曲线")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 120)
            } else {
                Chart {
                    ForEach(samples) { sample in
                        AreaMark(
                            x: .value("距离", sample.distanceKilometers),
                            y: .value("海拔变化", sample.changeMeters)
                        )
                        .foregroundStyle(Color.omniCobalt.opacity(0.18))
                        LineMark(
                            x: .value("距离", sample.distanceKilometers),
                            y: .value("海拔变化", sample.changeMeters)
                        )
                        .foregroundStyle(Color.omniCobalt)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    RuleMark(y: .value("起点", 0))
                        .foregroundStyle(Color.omniIdle)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ForEach(marks) { mark in
                        RuleMark(x: .value("距离", mark.distanceKilometers))
                            .foregroundStyle(Color.omniIdle)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        PointMark(
                            x: .value("距离", mark.distanceKilometers),
                            y: .value("海拔变化", mark.changeMeters)
                        )
                        .foregroundStyle(Color.omniInk)
                        .symbolSize(40)
                        .annotation(position: .top, spacing: 2) {
                            Text(mark.name)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.omniInk)
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.92), in: Capsule())
                        }
                    }
                }
                .chartYScale(domain: yDomain)
                .chartXAxisLabel("距离 (公里)")
                .chartYAxisLabel("海拔变化 (米)")
                .chartLegend(.hidden)
                .frame(height: 150)
                .accessibilityLabel(marks.isEmpty ? "海拔变化图，没有检查点" : "海拔变化图")
            }
            if !segments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(segments) { segment in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(segment.title)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.omniInk)
                                    .lineLimit(1)
                                Text("距离 \(routeKilometers(segment.distanceMeters)) · 爬升 \(routeMeters(segment.ascentMeters)) · 下降 \(routeMeters(segment.descentMeters))")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.omniMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .frame(height: min(CGFloat(segments.count) * 44, 160))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glass(radius: 22)
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

private func maxElevationText(_ points: [GeoPoint]) -> String {
    guard let maxElevation = RouteStats.maxElevation(points) else { return "—" }
    return routeMeters(maxElevation)
}
