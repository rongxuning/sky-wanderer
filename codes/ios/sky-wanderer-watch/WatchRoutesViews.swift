import SwiftUI

struct WatchRoutesView: View {
    @EnvironmentObject private var app: WatchAppState

    var body: some View {
        List {
            if app.routes.isEmpty {
                Text("还没有路线")
                    .foregroundStyle(Color.omniMuted)
            } else {
                ForEach(app.routes) { route in
                    NavigationLink(value: WatchRoutePush.detail(route.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.name)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.omniInk)
                            Text(routeSummary(route))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.skyMetricDistance)
                        }
                    }
                }
            }
        }
        .navigationTitle("路线")
        .navigationDestination(for: WatchRoutePush.self) { push in
            switch push {
            case .detail(let id):
                if let route = app.route(id: id) {
                    WatchRouteDetailView(route: route)
                } else {
                    Text("路线不存在")
                        .foregroundStyle(Color.omniMuted)
                }
            }
        }
    }

    private func routeSummary(_ route: SavedRoute) -> String {
        let distance = Format.kilometers(RouteStats.distance(route.points))
        let climb = Int(RouteStats.ascent(route.points).rounded())
        return "\(distance) 公里 · 爬升 \(climb) 米"
    }
}

enum WatchRoutePush: Hashable {
    case detail(String)
}

struct WatchRouteDetailView: View {
    var route: SavedRoute

    private var distanceMeters: Double {
        RouteStats.distance(route.points)
    }

    private var ascentMeters: Double {
        RouteStats.ascent(route.points)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(route.name)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.omniInk)
                Text(route.kind == .presetRunning ? "预设路线" : "导入路线")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    metric(Format.kilometers(distanceMeters), color: .skyMetricDistance)
                    metric(ascentText, color: .skyMetricElevation)
                }
                RouteMap(
                    route: route.points,
                    kilometers: RouteKilometers.markers(along: route.points),
                    cornerRadius: 12,
                    routeColor: Color.omniCobalt,
                    hidesMapControls: true
                )
                .frame(height: 110)
                if !route.waypoints.isEmpty {
                    Text("检查点 \(route.waypoints.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.omniMuted)
                    ForEach(Array(route.waypoints.prefix(6).enumerated()), id: \.offset) { index, point in
                        Text("\(index + 1). \(point.name.isEmpty ? "未命名" : point.name)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.omniInk)
                    }
                }
                Text("创建者 \(route.creatorLabel)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
            }
            .padding(.horizontal, 4)
        }
        .background(CanvasBackground())
        .navigationTitle("详情")
    }

    private var ascentText: String {
        guard ascentMeters > 0.5 else { return "—" }
        return "\(Int(ascentMeters.rounded()))"
    }

    private func metric(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }
}
