import CoreLocation
import SwiftUI

/// Where the glass pill is, in global coordinates. HomeView publishes this.
enum SkyTabBarAnchor: Equatable {
    /// The pill is on screen, but its frame has not been read yet.
    case unmeasured
    /// This stack is pushed, so the pill is not on screen.
    case hidden
    /// Global minY of the pill's top edge.
    case measured(CGFloat)
}

private struct SkyTabBarAnchorKey: EnvironmentKey {
    static let defaultValue = SkyTabBarAnchor.unmeasured
}

extension EnvironmentValues {
    var skyTabBarAnchor: SkyTabBarAnchor {
        get { self[SkyTabBarAnchorKey.self] }
        set { self[SkyTabBarAnchorKey.self] = newValue }
    }
}

enum StartSheet: String, Identifiable {
    case settings
    var id: String { rawValue }
}

struct StartMapView: View {
    @EnvironmentObject private var app: PhoneAppState
    @EnvironmentObject private var draft: WorkoutDraft
    @Binding var path: NavigationPath
    /// The training tab uses this as its root. There is nothing to pop; the glass bar leaves the tab.
    var showsBackButton = false
    /// False while another home tab is showing. The view stays mounted, so this is what stops a countdown.
    var isActive = true
    @StateObject private var location = LocationPermission()
    @ObservedObject private var basemap = SkyBasemapCenter.shared
    @State private var sheet: StartSheet?
    @State private var showSportRoulette = false
    /// 0 =「类型」docked in the column, 1 = screen center.
    @State private var typeToolFlight: CGFloat = 0
    @State private var companionToolsVisible = true
    @State private var rouletteTransitionTask: Task<Void, Never>?
    @State private var pickingRoute = false
    @State private var counting = false
    @State private var count = 3
    @State private var launching = false
    @State private var countdownTask: Task<Void, Never>?
    /// Global minY of the glass pill. `.unmeasured` until HomeView reads the bar.
    @Environment(\.skyTabBarAnchor) private var tabBarAnchor

    var body: some View {
        // Full-bleed map. The reader ignores the safe area so the icon column
        // centers on the screen, not on the band above the pill.
        GeometryReader { geo in
            ZStack {
                SkyTrackMap(
                    route: draft.plannedRoute(saved: app.savedRoutes, workouts: app.workouts).points,
                    showsUser: true,
                    userCoordinate: location.coordinate,
                    basemapMode: basemap.mode,
                    creditPlacement: .topCenter
                )
                .ignoresSafeArea()
                if counting {
                    countdown
                }
            }
            .overlay {
                if showSportRoulette {
                    SportRouletteOverlay(
                        selection: $draft.sport,
                        screenWidth: geo.size.width,
                        screenHeight: geo.size.height,
                        onDismiss: { closeSportRoulette(animated: true) }
                    )
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if showsBackButton {
                    Button {
                        cancelCountdown()
                        path = NavigationPath()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SkyTheme.Color.ink)
                            .frame(width: SkyTheme.Spacing.touchMin, height: SkyTheme.Spacing.touchMin)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回")
                    .padding(.leading, SkyTheme.Spacing.related)
                    .padding(.top, geo.safeAreaInsets.top)
                }
            }
            .overlay {
                // Absolute layout so「类型」can fly between the column and screen center.
                toolChrome(in: geo)
            }
            .overlay(alignment: .bottom) {
                // Move the bottom guide down by the clearance. The circle's bottom
                // edge then sits 16pt above the pill, and taps stay on the circle.
                startButton
                    .alignmentGuide(.bottom) { dimensions in
                        dimensions[.bottom] + startBottomPadding(in: geo)
                    }
            }
        }
        .ignoresSafeArea()
        .navigationBarHidden(true)
        .tint(SkyTheme.Color.primary)
        .onAppear {
            location.request()
            if countdownTask == nil {
                launching = false
            }
            if !isActive { cancelCountdown() }
        }
        .onChange(of: isActive) { _, active in
            if !active { cancelCountdown() }
        }
        .onDisappear {
            cancelCountdown()
            rouletteTransitionTask?.cancel()
            rouletteTransitionTask = nil
            showSportRoulette = false
            typeToolFlight = 0
            companionToolsVisible = true
        }
        .onChange(of: location.coordinate?.latitude) { _, _ in
            if let coordinate = location.coordinate {
                draft.origin = GeoPoint(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    altitude: 0,
                    timestamp: nil
                )
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .settings: StartSettingsSheet().presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $pickingRoute) {
            TrainingRoutePicker()
        }
    }

    private var countdown: some View {
        Text("\(count)")
            .font(.system(size: 64, weight: .bold))
            .foregroundStyle(SkyTheme.Color.primary)
            .frame(width: 140, height: 140)
            .background(.ultraThinMaterial, in: Circle())
            .overlay {
                Circle().strokeBorder(SkyTheme.Color.card.opacity(0.55), lineWidth: 0.5)
            }
            .accessibilityLabel("倒计时 \(count)")
    }

    private func toolChrome(in geo: GeometryProxy) -> some View {
        let typePoint = StartMapChrome.typeToolPosition(
            progress: ChromeLength(typeToolFlight),
            screenWidth: ChromeLength(geo.size.width),
            screenHeight: ChromeLength(geo.size.height)
        )
        return ZStack(alignment: .topLeading) {
            companionToolColumn
                .offset(
                    x: CGFloat(StartMapChrome.toolLeading),
                    y: toolColumnOrigin(in: geo)
                )
                .opacity(companionToolsVisible ? 1 : 0)
                .allowsHitTesting(companionToolsVisible && !showSportRoulette)
                .accessibilityHidden(!companionToolsVisible || showSportRoulette)

            toolButton(draft.sport.symbol, StartMapChrome.typeTool.label) {
                performTool("类型")
            }
            // Match the roulette midline scale so the handoff does not pop.
            .scaleEffect(1 + CGFloat(SportRouletteGeometry.centerScale - 1) * typeToolFlight)
            .opacity(showSportRoulette ? 0 : 1)
            .allowsHitTesting(!showSportRoulette)
            .accessibilityHidden(showSportRoulette)
            .position(x: CGFloat(typePoint.x), y: CGFloat(typePoint.y))
        }
        // Full-bleed so `.position` uses screen coordinates; empty areas pass hits through.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var companionToolColumn: some View {
        VStack(spacing: CGFloat(StartMapChrome.toolGap)) {
            Color.clear
                .frame(
                    width: CGFloat(StartMapChrome.toolDiameter),
                    height: CGFloat(StartMapChrome.toolDiameter)
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ForEach(StartMapChrome.companionTools, id: \.label) { tool in
                toolButton(tool.symbol, tool.label) {
                    performTool(tool.label)
                }
            }
        }
    }

    private func toolButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SkyTheme.Color.onStarryGray)
                .frame(width: CGFloat(StartMapChrome.toolDiameter), height: CGFloat(StartMapChrome.toolDiameter))
                .background(SkyTheme.Color.starryGray, in: Circle())
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(label)
    }

    private var startButton: some View {
        Button(action: start) {
            Text("开始")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(SkyTheme.Color.onPrimary)
                .frame(width: CGFloat(StartMapChrome.startDiameter), height: CGFloat(StartMapChrome.startDiameter))
                .background(SkyTheme.Color.primary, in: Circle())
                .shadow(
                    color: SkyTheme.Shadow.card.color.opacity(SkyTheme.Shadow.card.opacity),
                    radius: SkyTheme.Shadow.card.radius,
                    y: SkyTheme.Shadow.card.y
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("开始")
    }

    /// Distance from the bottom of this full-bleed reader to the bottom of Start.
    /// The glass pill is not a system tab bar, and `safeAreaInsets.bottom` does not
    /// include it, so the padding is measured from the pill's top.
    private func startBottomPadding(in geo: GeometryProxy) -> CGFloat {
        let safe = ChromeLength(geo.safeAreaInsets.bottom)
        switch tabBarAnchor {
        case .hidden:
            return CGFloat(safe + StartMapChrome.gapAboveTabBar)
        case .unmeasured:
            return CGFloat(StartMapChrome.fallbackStartBottomPadding(safeAreaBottom: safe))
        case .measured(let tabBarTop):
            let resolved = StartMapChrome.startBottomPadding(
                mapMaxY: ChromeLength(geo.frame(in: .global).maxY),
                tabBarMinY: ChromeLength(tabBarTop)
            )
            return CGFloat(resolved ?? StartMapChrome.fallbackStartBottomPadding(safeAreaBottom: safe))
        }
    }

    private func toolColumnOrigin(in geo: GeometryProxy) -> CGFloat {
        CGFloat(StartMapChrome.toolColumnOriginY(screenHeight: ChromeLength(geo.size.height)))
    }

    private func performTool(_ label: String) {
        switch label {
        case "类型":
            if showSportRoulette || typeToolFlight > 0.01 {
                closeSportRoulette(animated: true)
            } else {
                openSportRoulette()
            }
        case "路线":
            closeSportRoulette(animated: false)
            cancelCountdown()
            pickingRoute = true
        case "组队":
            closeSportRoulette(animated: false)
            cancelCountdown()
            path.append(TrainRoute.team)
        case "设置":
            closeSportRoulette(animated: false)
            sheet = .settings
        default:
            break
        }
    }

    private func openSportRoulette() {
        rouletteTransitionTask?.cancel()
        rouletteTransitionTask = Task { @MainActor in
            withAnimation(.easeOut(duration: Double(StartMapChrome.rouletteOpenCompanionFade))) {
                companionToolsVisible = false
            }
            withAnimation(.spring(
                response: Double(StartMapChrome.rouletteOpenFly),
                dampingFraction: 0.86
            )) {
                typeToolFlight = 1
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
            typeToolFlight = 0
            companionToolsVisible = true
            return
        }
        rouletteTransitionTask = Task { @MainActor in
            withAnimation(.easeOut(duration: Double(StartMapChrome.rouletteCloseFade))) {
                showSportRoulette = false
            }
            // Let the flying type button reappear under the fading roulette.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(
                response: Double(StartMapChrome.rouletteCloseFly),
                dampingFraction: 0.86
            )) {
                typeToolFlight = 0
                companionToolsVisible = true
            }
        }
    }

    private func start() {
        guard !launching else { return }
        closeSportRoulette(animated: false)
        if app.activeSession?.phase == .running {
            launching = true
            path.append(TrainRoute.live)
            return
        }
        guard draft.countdown else {
            launching = true
            path.append(TrainRoute.live)
            return
        }
        launching = true
        counting = true
        count = 3
        countdownTask = Task { @MainActor in
            for value in stride(from: 3, through: 1, by: -1) {
                if Task.isCancelled { return }
                count = value
                do {
                    try await Task.sleep(nanoseconds: 700_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            counting = false
            countdownTask = nil
            path.append(TrainRoute.live)
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        counting = false
        launching = false
    }
}

struct StartSettingsSheet: View {
    @EnvironmentObject private var app: PhoneAppState
    @EnvironmentObject private var draft: WorkoutDraft

    var body: some View {
        VStack(alignment: .leading, spacing: SkyTheme.Spacing.related) {
            Text("设置")
                .font(SkyTheme.Font.title)
                .foregroundStyle(SkyTheme.Color.ink)
            Text("\(draft.sport.title) · \(plannedTitle)")
                .font(SkyTheme.Font.subheadline)
                .foregroundStyle(SkyTheme.Color.secondary)
            Toggle(isOn: $draft.countdown) {
                Text("开始前倒计时")
                    .font(SkyTheme.Font.headline)
                    .foregroundStyle(SkyTheme.Color.ink)
            }
            .tint(SkyTheme.Color.primary)
            Text("有健康数据权限时，这次训练会写入 Apple 健康。写不进去时，运动页会标明本地模拟。组队位置来自本机模拟，没有服务器。")
                .font(SkyTheme.Font.footnote)
                .foregroundStyle(SkyTheme.Color.secondary)
            Spacer(minLength: 0)
        }
        .padding(SkyTheme.Spacing.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SkyTheme.Color.grouped)
        .presentationBackground(SkyTheme.Color.grouped)
        .tint(SkyTheme.Color.primary)
    }

    private var plannedTitle: String {
        let planned = draft.plannedRoute(saved: app.savedRoutes, workouts: app.workouts)
        return planned.id == PlannedRoute.free.id ? "自由跑" : planned.name
    }
}

/// Picks a planned route for the upcoming run or hike. The 路线 tab is unchanged.
struct TrainingRoutePicker: View {
    @EnvironmentObject private var app: PhoneAppState
    @EnvironmentObject private var draft: WorkoutDraft
    @Environment(\.dismiss) private var dismiss

    private var plannedID: String {
        draft.plannedRoute(saved: app.savedRoutes, workouts: app.workouts).id
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: SkyTheme.Spacing.related) {
                    Button {
                        draft.selectFreeRun()
                        dismiss()
                    } label: {
                        FreeRunSummaryCard(selected: plannedID == PlannedRoute.free.id)
                    }
                    .buttonStyle(.plain)

                    if app.importedRoutes.isEmpty {
                        Text("还没有导入的路线")
                            .font(SkyTheme.Font.footnote)
                            .foregroundStyle(SkyTheme.Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, SkyTheme.Spacing.related)
                    } else {
                        ForEach(app.importedRoutes) { route in
                            Button {
                                draft.select(route: route)
                                dismiss()
                            } label: {
                                RouteSummaryCard(route: route, selected: draft.routeID == route.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, SkyTheme.Spacing.screenInset)
                .padding(.vertical, SkyTheme.Spacing.screenInset)
            }
            .background(SkyTheme.Color.grouped)
            .navigationTitle("路线")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(SkyTheme.Color.grouped, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(SkyTheme.Color.grouped)
        .tint(SkyTheme.Color.primary)
    }
}

struct TeamPickerView: View {
    @EnvironmentObject private var draft: WorkoutDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SkyTheme.Spacing.related) {
                Text("组队")
                    .font(SkyTheme.Font.largeTitle)
                    .foregroundStyle(SkyTheme.Color.ink)
                Text("选好队友后开始运动，可以看到他们的位置、配速和心率。这些位置由本机模拟，没有服务器。")
                    .font(SkyTheme.Font.subheadline)
                    .foregroundStyle(SkyTheme.Color.secondary)
                ForEach(SampleLibrary.teammates) { person in
                    Button {
                        toggle(person.id)
                    } label: {
                        HStack {
                            Text(person.name)
                                .font(SkyTheme.Font.title3)
                            Spacer()
                            Image(systemName: draft.memberIDs.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(SkyTheme.Color.primary)
                        }
                        .foregroundStyle(SkyTheme.Color.ink)
                        .padding(SkyTheme.Spacing.cardPadding)
                        .frame(minHeight: SkyTheme.Spacing.touchMin)
                        .background(
                            SkyTheme.Color.card,
                            in: RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: SkyTheme.Radius.card, style: .continuous)
                                .stroke(SkyTheme.Color.cardBorder, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    dismiss()
                } label: {
                    Text("完成")
                        .font(SkyTheme.Font.headline)
                        .foregroundStyle(SkyTheme.Color.onPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: SkyTheme.Spacing.touchMin)
                        .background(SkyTheme.Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, SkyTheme.Spacing.related)
            }
            .padding(SkyTheme.Spacing.section)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyTheme.Color.grouped.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .tint(SkyTheme.Color.primary)
    }

    private func toggle(_ id: String) {
        if let index = draft.memberIDs.firstIndex(of: id) {
            draft.memberIDs.remove(at: index)
        } else {
            draft.memberIDs.append(id)
        }
    }
}
