import CoreLocation
import SwiftUI

enum StartSheet: String, Identifiable {
    case type
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
    @State private var sheet: StartSheet?
    @State private var pickingRoute = false
    @State private var counting = false
    @State private var count = 3
    @State private var launching = false
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        // Full-bleed map. The glass tab bar is an ancestor safe-area inset, so padding
        // the controls by that bottom inset keeps them above the bar. The bar stays visible.
        GeometryReader { geo in
            ZStack {
                RouteMap(
                    route: [],
                    planned: draft.plannedRoute(saved: app.savedRoutes, workouts: app.workouts).points,
                    showsUser: true,
                    userCoordinate: location.coordinate
                )
                .ignoresSafeArea()
                if counting {
                    countdown
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
            .overlay(alignment: .bottom) {
                startBar
                    .padding(.horizontal, SkyTheme.Spacing.screenInset)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 10)
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
        .onDisappear { cancelCountdown() }
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
            case .type: TypeSheet().presentationDetents([.height(280)])
            case .settings: StartSettingsSheet().presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $pickingRoute) {
            TrainingRoutePicker()
        }
    }

    private var plannedName: String {
        let planned = draft.plannedRoute(saved: app.savedRoutes, workouts: app.workouts)
        return planned.id == PlannedRoute.free.id ? "自由跑" : planned.name
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

    private var startBar: some View {
        HStack(spacing: 0) {
            barButton("square.grid.2x2", "类型") { sheet = .type }
            barButton(
                "point.topleft.down.curvedto.point.bottomright.up",
                "路线",
                value: plannedName
            ) {
                cancelCountdown()
                pickingRoute = true
            }
            barButton("play.fill", "开始", prominent: true, action: start)
            barButton("person.2", "组队", badge: draft.memberIDs.count) {
                cancelCountdown()
                path.append(TrainRoute.team)
            }
            barButton("gearshape.fill", "设置") { sheet = .settings }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(SkyTheme.Color.card.opacity(0.55), lineWidth: 0.5)
        }
        .shadow(color: SkyTheme.Shadow.card.color.opacity(0.08), radius: 16, y: 4)
    }

    /// Running and hiking share this bar. Choosing a route is not limited to one sport.
    private func barButton(
        _ symbol: String,
        _ title: String,
        prominent: Bool = false,
        badge: Int = 0,
        value: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                    if badge > 0 {
                        Text("\(badge)")
                            .font(SkyTheme.Font.caption)
                            .foregroundStyle(SkyTheme.Color.onPrimary)
                            .padding(3)
                            .background(SkyTheme.Color.primary, in: Circle())
                            .offset(x: 10, y: -6)
                    }
                }
                Text(title)
                    .font(SkyTheme.Font.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? SkyTheme.Color.onPrimary : SkyTheme.Color.ink)
            .frame(maxWidth: .infinity)
            .frame(minHeight: SkyTheme.Spacing.touchMin)
            .background {
                if prominent {
                    Capsule().fill(SkyTheme.Color.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.map { "\(title)，\($0)" } ?? title)
    }

    private func start() {
        guard !launching else { return }
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

struct TypeSheet: View {
    @EnvironmentObject private var draft: WorkoutDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: SkyTheme.Spacing.related) {
            Text("类型")
                .font(SkyTheme.Font.title)
                .foregroundStyle(SkyTheme.Color.ink)
                .padding(.top, SkyTheme.Spacing.related)
            ForEach(SportKind.allCases) { sport in
                Button {
                    draft.sport = sport
                    dismiss()
                } label: {
                    HStack {
                        Text(sport.title)
                            .font(SkyTheme.Font.title2)
                        Spacer()
                        if draft.sport == sport {
                            Image(systemName: "checkmark")
                                .font(SkyTheme.Font.headline)
                                .foregroundStyle(SkyTheme.Color.primary)
                        }
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
                            .stroke(
                                draft.sport == sport ? SkyTheme.Color.primary : SkyTheme.Color.cardBorder,
                                lineWidth: draft.sport == sport ? 1.5 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(SkyTheme.Spacing.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SkyTheme.Color.grouped)
        .presentationBackground(SkyTheme.Color.grouped)
        .tint(SkyTheme.Color.primary)
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
            Text("有健康数据权限时，这次徒步或跑步会写入 Apple 健康。写不进去时，运动页会标明本地模拟。组队位置来自本机模拟，没有服务器。")
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
