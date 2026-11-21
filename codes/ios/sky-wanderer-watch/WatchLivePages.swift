import SwiftUI

/// Shared live layout for phone-synced and watch-started workouts.
struct WatchLiveMetricsPage: View {
    var sportTitle: String
    var elapsed: TimeInterval
    var distanceMeters: Double
    var paceSecPerKm: Double
    var heartRate: Double
    var cadence: Double
    var altitudeMeters: Double
    var paused: Bool
    var status: String? = nil
    var onEnd: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sportTitle)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
                if paused {
                    Text("暂停")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.skyMetricDuration)
                }
                Spacer(minLength: 4)
                if let onEnd {
                    Button(action: onEnd) {
                        Text("结束")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.omniCoral, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.clock(elapsed))
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.skyMetricDuration)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Format.kilometers(distanceMeters))
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.skyMetricDistance)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 8) {
                watchMetric(Format.pace(paceSecPerKm), color: .skyMetricPace)
                watchMetric(Format.integer(heartRate), color: .skyMetricHeart)
            }
            HStack(alignment: .top, spacing: 8) {
                watchMetric(Format.integer(cadence), color: .skyMetricPace)
                watchMetric(altitudeText, color: .skyMetricElevation)
            }
            if let status, !status.isEmpty {
                Text(status)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var altitudeText: String {
        guard altitudeMeters.isFinite, abs(altitudeMeters) > 0.05 else { return "—" }
        return String(Int(altitudeMeters.rounded()))
    }

    private func watchMetric(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }
}

struct WatchLiveMapPage: View {
    var route: [GeoPoint]
    var kilometers: [KilometerMarker]
    var showsUser: Bool
    var userFix: GeoPoint?

    var body: some View {
        RouteMap(
            route: route,
            kilometers: kilometers,
            showsUser: showsUser,
            userCoordinate: userFix?.coordinate,
            cornerRadius: 14,
            routeColor: Color.omniCobalt,
            routeLineWidth: 3,
            hidesMapControls: true
        )
        .padding(2)
    }
}

struct WatchPhoneLiveView: View {
    @ObservedObject var mirror: WatchCompanionMirror

    var body: some View {
        let snap = mirror.snapshot
        TabView {
            WatchLiveMetricsPage(
                sportTitle: snap.sport.title,
                elapsed: snap.elapsed,
                distanceMeters: snap.distanceMeters,
                paceSecPerKm: snap.paceSecPerKm,
                heartRate: snap.heartRate,
                cadence: snap.cadence,
                altitudeMeters: snap.altitudeMeters,
                paused: snap.paused,
                status: "手机同步"
            )
            WatchLiveMapPage(
                route: snap.routePoints,
                kilometers: snap.kilometerMarks,
                showsUser: snap.userFix != nil,
                userFix: snap.userFix
            )
        }
        .tabViewStyle(.verticalPage)
        .background(CanvasBackground())
    }
}
